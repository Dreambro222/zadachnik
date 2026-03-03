import SwiftUI
import SwiftData
import QuickLook
import UniformTypeIdentifiers

// MARK: - Entity type for linking

enum AttachmentEntity {
    case person(UUID)
    case project(UUID)
    case task(UUID)
    case note(UUID)

    var id: UUID {
        switch self {
        case .person(let id), .project(let id), .task(let id), .note(let id): return id
        }
    }
}

// MARK: - Reusable attachment section

struct AttachmentSection: View {
    @Environment(\.modelContext) private var modelContext

    let entity: AttachmentEntity
    let attachments: [Attachment]   // filtered by parent, passed in

    @State private var showFilePicker  = false
    @State private var previewURL:   URL?
    @State private var isDropTargeted  = false
    @State private var isExpanded      = true

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                if isExpanded {
                    if attachments.isEmpty {
                        emptyZone
                    } else {
                        fileList
                    }
                }
            }
        } label: {
            HStack {
                Label("Файлы", systemImage: "paperclip")
                    .font(.subheadline).fontWeight(.semibold)

                if !attachments.isEmpty {
                    Text("\(attachments.count)")
                        .font(.caption).fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.secondary, in: Capsule())
                }

                Spacer()

                // Add button
                Button { showFilePicker = true } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                // Collapse toggle
                Button {
                    withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        // Drop onto the whole GroupBox
        .onDrop(of: [.fileURL, .image, .pdf, .plainText, .data],
                isTargeted: $isDropTargeted) { providers in
            Task { await importFromProviders(providers) }
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isDropTargeted ? Color.blue.opacity(0.6) : Color.clear,
                    lineWidth: 2
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
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
    }

    // MARK: - Empty zone

    private var emptyZone: some View {
        VStack(spacing: 8) {
            Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "paperclip")
                .font(.system(size: 28))
                .foregroundStyle(isDropTargeted ? .blue : .secondary)
                .animation(.spring(duration: 0.2), value: isDropTargeted)

            Text(isDropTargeted ? "Отпустите файл" : "Перетащите или нажмите «+»")
                .font(.caption)
                .foregroundStyle(isDropTargeted ? .blue : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            isDropTargeted
                ? Color.blue.opacity(0.06)
                : Color.secondary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    // MARK: - File list

    private var fileList: some View {
        VStack(spacing: 0) {
            ForEach(attachments) { att in
                AttachmentRow(att: att, onPreview: { previewURL = att.fileURL })
                    .contextMenu {
                        if let url = att.fileURL {
                            Button { previewURL = url } label: {
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

                if att.id != attachments.last?.id {
                    Divider().padding(.leading, 44)
                }
            }

            // Drop hint when list has files
            if isDropTargeted {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("Отпустите для добавления").font(.caption).foregroundStyle(.blue)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Import

    private func importFromProviders(_ providers: [NSItemProvider]) async {
        let dir = attachmentsDirectory()
        for provider in providers {
            guard let url = await loadFileURL(from: provider) else { continue }
            await MainActor.run { copyAndLink(url: url, to: dir) }
        }
        await MainActor.run { try? modelContext.save() }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url)
                } else if let url = item as? URL {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func importFile(from url: URL) {
        let dir = attachmentsDirectory()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        copyAndLink(url: url, to: dir)
    }

    private func copyAndLink(url: URL, to dir: URL) {
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
            att.displayName = url.lastPathComponent
            linkAttachment(att)
            modelContext.insert(att)
        } catch {
            print("[AttachmentSection] copy failed: \(error)")
        }
    }

    private func linkAttachment(_ att: Attachment) {
        switch entity {
        case .person(let id):  att.linkedPersonId  = id
        case .project(let id): att.linkedProjectId = id
        case .task(let id):    att.linkedTaskId    = id
        case .note(let id):    att.linkedNoteId    = id
        }
    }

    private func deleteAttachment(_ att: Attachment) {
        if let url = att.fileURL { try? FileManager.default.removeItem(at: url) }
        modelContext.delete(att)
        try? modelContext.save()
    }

    private func attachmentsDirectory() -> URL {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "pdf":         return "application/pdf"
        case "txt", "md":   return "text/plain"
        case "mp4":         return "video/mp4"
        case "mov":         return "video/quicktime"
        case "mp3":         return "audio/mpeg"
        case "zip":         return "application/zip"
        default:            return "application/octet-stream"
        }
    }
}

// MARK: - Compact attachment row

struct AttachmentRow: View {
    let att: Attachment
    let onPreview: () -> Void

    var body: some View {
        Button(action: onPreview) {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: att.fileIconColor).opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: att.fileIcon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(hex: att.fileIconColor))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(att.visibleName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(att.fileSizeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(att.createdAt.relativeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Helper view that wraps Query + Section together

/// Use this in detail views where you don't have direct access to filtered attachments.
struct LinkedAttachmentSection: View {
    let entity: AttachmentEntity

    @Query private var attachments: [Attachment]

    init(entity: AttachmentEntity) {
        self.entity = entity
        let id = entity.id
        switch entity {
        case .person:
            _attachments = Query(
                filter: #Predicate<Attachment> { $0.linkedPersonId == id },
                sort: \Attachment.createdAt, order: .reverse
            )
        case .project:
            _attachments = Query(
                filter: #Predicate<Attachment> { $0.linkedProjectId == id },
                sort: \Attachment.createdAt, order: .reverse
            )
        case .task:
            _attachments = Query(
                filter: #Predicate<Attachment> { $0.linkedTaskId == id },
                sort: \Attachment.createdAt, order: .reverse
            )
        case .note:
            _attachments = Query(
                filter: #Predicate<Attachment> { $0.linkedNoteId == id },
                sort: \Attachment.createdAt, order: .reverse
            )
        }
    }

    var body: some View {
        AttachmentSection(entity: entity, attachments: attachments)
    }
}
