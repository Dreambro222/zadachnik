import SwiftData
import Foundation

@Model
final class Interaction {
    var id: UUID
    var date: Date
    var typeRaw: String
    var notes: String
    var result: String      // What came out of this interaction

    // Media attachment
    var audioFileName: String?  // relative filename in Documents/VoiceMemos/
    var transcription: String   // auto-transcribed text
    var summary: String         // AI-generated meeting summary (JSON: topic/agreements/actions)

    var person: Person?

    var type: InteractionType {
        get { InteractionType(rawValue: typeRaw) ?? .other }
        set { typeRaw = newValue.rawValue }
    }

    var audioFileURL: URL? {
        guard let fileName = audioFileName else { return nil }
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMemos", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    init(
        date: Date = Date(),
        type: InteractionType = .meeting,
        notes: String = "",
        result: String = "",
        audioFileName: String? = nil
    ) {
        self.id = UUID()
        self.date = date
        self.typeRaw = type.rawValue
        self.notes = notes
        self.result = result
        self.audioFileName = audioFileName
        self.transcription = ""
        self.summary = ""
    }
}
