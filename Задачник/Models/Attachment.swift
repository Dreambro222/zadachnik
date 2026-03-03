import SwiftData
import Foundation

@Model
final class Attachment {
    var id: UUID
    var fileName: String      // UUID-prefixed stored name
    var displayName: String?  // original file name shown to user
    var mimeType: String
    var fileSize: Int64
    var createdAt: Date

    // Links to entities (UUID stored as string for SwiftData predicate compatibility)
    var linkedTaskId:    UUID?
    var linkedNoteId:    UUID?
    var linkedPersonId:  UUID?
    var linkedProjectId: UUID?

    var fileURL: URL? {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    var isImage: Bool  { mimeType.hasPrefix("image/") }
    var isPDF:   Bool  { mimeType == "application/pdf" }

    var visibleName: String { displayName ?? fileName }

    var fileSizeLabel: String {
        let bytes = Double(fileSize)
        if bytes < 1024       { return "\(fileSize) B" }
        if bytes < 1_048_576  { return String(format: "%.1f KB", bytes / 1024) }
        return String(format: "%.1f MB", bytes / 1_048_576)
    }

    var fileIcon: String {
        if isImage { return "photo.fill" }
        if isPDF   { return "doc.richtext.fill" }
        switch mimeType {
        case "text/plain", "text/markdown":  return "doc.text.fill"
        case "video/mp4", "video/quicktime": return "film.fill"
        case "audio/mpeg":                   return "music.note"
        case "application/zip":              return "archivebox.fill"
        case let m where m.contains("word"):  return "doc.fill"
        case let m where m.contains("sheet"): return "tablecells.fill"
        default: return "doc.fill"
        }
    }

    var fileIconColor: String {
        if isImage { return "#007AFF" }
        if isPDF   { return "#FF3B30" }
        switch mimeType {
        case "video/mp4", "video/quicktime": return "#AF52DE"
        case "audio/mpeg":                   return "#FF2D55"
        case "application/zip":              return "#FF9500"
        default: return "#8E8E93"
        }
    }

    init(fileName: String, mimeType: String, fileSize: Int64) {
        self.id          = UUID()
        self.fileName    = fileName
        self.mimeType    = mimeType
        self.fileSize    = fileSize
        self.createdAt   = Date()
    }
}
