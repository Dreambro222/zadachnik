import SwiftData
import Foundation

enum MaterialType: String, Codable, CaseIterable, Identifiable {
    case link  = "link"
    case file  = "file"
    case image = "image"
    case note  = "note"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .link:  return "link"
        case .file:  return "doc.fill"
        case .image: return "photo.fill"
        case .note:  return "note.text"
        }
    }
}

@Model
final class MaterialLink {
    var id: UUID
    var url: String
    var title: String
    var previewText: String
    var typeRaw: String
    var tags: [String]
    var createdAt: Date

    var type: MaterialType {
        get { MaterialType(rawValue: typeRaw) ?? .link }
        set { typeRaw = newValue.rawValue }
    }

    var displayTitle: String {
        title.isEmpty ? url : title
    }

    var domain: String {
        URL(string: url)?.host ?? url
    }

    init(
        url: String,
        title: String = "",
        previewText: String = "",
        type: MaterialType = .link,
        tags: [String] = []
    ) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.previewText = previewText
        self.typeRaw = type.rawValue
        self.tags = tags
        self.createdAt = Date()
    }
}
