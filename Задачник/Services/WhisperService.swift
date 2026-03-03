import Foundation
import Speech

// MARK: - Whisper Transcription Service
// Транскрибирует аудио через OpenAI Whisper API (приоритет) или SFSpeechRecognizer (fallback).
// Whisper поддерживает оба голоса, 99 языков, качество значительно лучше SFSpeechRecognizer.

enum TranscriptionMethod {
    case whisper
    case local
}

struct TranscriptionResult {
    let text: String
    let method: TranscriptionMethod
    let language: String?
}

final class WhisperService {
    static let shared = WhisperService()
    private init() {}

    // Стоимость: ~$0.006 за минуту аудио
    private let whisperURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    // MARK: - Main transcription entry point

    /// Транскрибирует файл. Сначала пробует Whisper API, при ошибке — локальный SFSpeechRecognizer.
    func transcribe(url: URL, language: String = "ru") async -> TranscriptionResult {
        NSLog("[Whisper] Start transcription: \(url.lastPathComponent)")

        // Пробуем Whisper API если есть ключ
        if let apiKey = KeychainHelper.load(KeychainKey.openAIAPIKey), !apiKey.isEmpty {
            do {
                let text = try await transcribeWithWhisper(url: url, apiKey: apiKey, language: language)
                NSLog("[Whisper] Whisper API success, length=\(text.count)")
                return TranscriptionResult(text: text, method: .whisper, language: language)
            } catch {
                NSLog("[Whisper] Whisper API failed: \(error.localizedDescription), fallback to local")
            }
        } else {
            NSLog("[Whisper] No OpenAI key, using local SFSpeechRecognizer")
        }

        // Fallback: локальная транскрипция
        let localText = await transcribeLocally(url: url, language: language)
        return TranscriptionResult(text: localText, method: .local, language: language)
    }

    // MARK: - Whisper API

    private func transcribeWithWhisper(url: URL, apiKey: String, language: String) async throws -> String {
        let audioData = try Data(contentsOf: url)
        guard !audioData.isEmpty else { throw WhisperError.emptyFile }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: whisperURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()

        // model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)

        // language field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(language)\r\n".data(using: .utf8)!)

        // response_format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)

        // file field — Whisper accepts: mp3, mp4, mpeg, mpga, m4a, wav, webm, ogg, opus
        let ext = url.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "m4a":              mimeType = "audio/m4a"
        case "mp3", "mpga":     mimeType = "audio/mpeg"
        case "mp4":              mimeType = "audio/mp4"
        case "wav":              mimeType = "audio/wav"
        case "webm":             mimeType = "audio/webm"
        case "ogg", "oga":      mimeType = "audio/ogg"
        case "opus":             mimeType = "audio/opus"
        case "flac":             mimeType = "audio/flac"
        default:                 mimeType = "audio/mpeg"
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            NSLog("[Whisper] API error \(httpResponse.statusCode): \(errorBody)")
            throw WhisperError.apiError(httpResponse.statusCode, errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw WhisperError.parseError
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Local SFSpeechRecognizer fallback

    private func transcribeLocally(url: URL, language: String) async -> String {
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            await requestSpeechPermission()
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return "" }
        }

        let locale = Locale(identifier: language == "ru" ? "ru-RU" : language)
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: .current)
        guard let recognizer, recognizer.isAvailable else { return "" }

        return await withCheckedContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    private func requestSpeechPermission() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }
}

// MARK: - Errors

enum WhisperError: LocalizedError {
    case emptyFile
    case invalidResponse
    case apiError(Int, String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .emptyFile:              return "Аудиофайл пустой"
        case .invalidResponse:        return "Некорректный ответ сервера"
        case .apiError(let code, let msg): return "Whisper API ошибка \(code): \(msg)"
        case .parseError:             return "Не удалось разобрать ответ Whisper"
        }
    }
}
