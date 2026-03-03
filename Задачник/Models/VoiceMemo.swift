import SwiftData
import Foundation

enum CallSource: String, Codable, CaseIterable {
    case microphone = "microphone"
    case telegram   = "telegram"
    case zoom       = "zoom"
    case phone      = "phone"
    case other      = "other"

    var label: String {
        switch self {
        case .microphone: return "Микрофон"
        case .telegram:   return "Telegram"
        case .zoom:       return "Zoom"
        case .phone:      return "Телефон"
        case .other:      return "Другое"
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic.fill"
        case .telegram:   return "paperplane.fill"
        case .zoom:       return "video.fill"
        case .phone:      return "phone.fill"
        case .other:      return "waveform"
        }
    }
}

@Model
final class VoiceMemo {
    var id: UUID
    var fileName: String          // relative filename in Documents/VoiceMemos/
    var duration: TimeInterval
    var transcription: String
    var createdAt: Date
    var isCallRecording: Bool
    var callSourceRaw: String     // CallSource.rawValue
    var callerName: String        // имя собеседника (опционально)
    var linkedPersonId: UUID?     // привязка к Person
    var linkedNoteId: UUID?
    var linkedTaskId: UUID?
    var whisperUsed: Bool         // true = транскрибирован через Whisper API

    var callSource: CallSource {
        get { CallSource(rawValue: callSourceRaw) ?? .microphone }
        set { callSourceRaw = newValue.rawValue }
    }

    var fileURL: URL? {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMemos", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    var durationLabel: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    init(
        fileName: String,
        duration: TimeInterval = 0,
        isCallRecording: Bool = false,
        callSource: CallSource = .microphone,
        callerName: String = "",
        linkedPersonId: UUID? = nil
    ) {
        self.id = UUID()
        self.fileName = fileName
        self.duration = duration
        self.transcription = ""
        self.createdAt = Date()
        self.isCallRecording = isCallRecording
        self.callSourceRaw = callSource.rawValue
        self.callerName = callerName
        self.linkedPersonId = linkedPersonId
        self.linkedNoteId = nil
        self.linkedTaskId = nil
        self.whisperUsed = false
    }
}
