import SwiftData
import Foundation

@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer

    private init() {
        let schema = Schema([
            Project.self,
            TaskItem.self,
            QuickNote.self,
            Person.self,
            Interaction.self,
            Deal.self,
            MaterialLink.self,
            RecurringPattern.self,
            CustomField.self,
            CustomFieldValue.self,
            VoiceMemo.self,
            Attachment.self
        ])

        // Store in ~/Library/Application Support/Zadachnik/
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Zadachnik", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let storeURL = appSupport.appendingPathComponent("zadachnik.store")

        do {
            let config = ModelConfiguration(url: storeURL)
            container = try ModelContainer(for: schema, configurations: [config])
            print("[Задачник] SwiftData initialized at: \(storeURL.path)")
        } catch {
            fatalError("[Задачник] Could not initialize SwiftData: \(error)")
        }
    }
}
