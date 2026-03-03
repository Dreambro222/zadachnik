import Foundation

// MARK: - Telegram Bot notification service

@MainActor
final class TelegramService: ObservableObject {
    static let shared = TelegramService()

    @Published var lastError: String?
    @Published var isSending = false

    private var botToken: String { KeychainHelper.load(KeychainKey.telegramBotToken) ?? "" }
    private var chatId: String   { KeychainHelper.load(KeychainKey.telegramChatId)   ?? "" }

    private init() {}

    var isConfigured: Bool {
        !botToken.isEmpty && !chatId.isEmpty
    }

    // MARK: - Send message

    func send(_ text: String, parseMode: String = "HTML") async {
        guard isConfigured else {
            lastError = "Telegram не настроен. Укажите токен и chat ID в Настройках."
            return
        }

        isSending = true
        defer { isSending = false }
        lastError = nil

        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage") else {
            lastError = "Неверный URL Telegram"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "chat_id":    chatId,
            "text":       text,
            "parse_mode": parseMode
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                lastError = "Telegram ошибка: \(msg)"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Convenience helpers

    func sendError(_ message: String, context: String = "") async {
        let text = """
        🔴 <b>Ошибка в Задачнике</b>
        \(message)
        \(context.isEmpty ? "" : "\n<code>\(context)</code>")
        """
        await send(text)
    }

    func sendTaskReminder(_ taskTitle: String, deadline: Date?) async {
        var text = "📌 <b>Напоминание о задаче</b>\n\(taskTitle)"
        if let d = deadline {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            fmt.locale = Locale(identifier: "ru_RU")
            text += "\n🗓 Дедлайн: \(fmt.string(from: d))"
        }
        await send(text)
    }

    // MARK: - Validate

    func validateConnection() async throws {
        guard !botToken.isEmpty else { throw TelegramError.notConfigured }

        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/getMe") else {
            throw TelegramError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Неизвестная ошибка"
            throw TelegramError.apiError(msg)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard json?["ok"] as? Bool == true else {
            throw TelegramError.apiError("Бот не найден. Проверьте токен.")
        }
    }
}

// MARK: - TelegramError

enum TelegramError: LocalizedError {
    case notConfigured
    case invalidURL
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:   return "Telegram не настроен. Укажите токен и chat ID в Настройках."
        case .invalidURL:      return "Неверный URL"
        case .apiError(let m): return m
        }
    }
}
