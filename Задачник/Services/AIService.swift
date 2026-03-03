import Foundation

// MARK: - Meeting Summary

struct MeetingSummary: Codable {
    let topic: String
    let agreements: [String]
    let actions: [String]
}

// MARK: - Models

struct AttachedImage: Identifiable, Equatable {
    let id = UUID()
    let base64: String      // base64-encoded JPEG/PNG
    let mimeType: String    // "image/jpeg" or "image/png"
    /// Downscaled preview data for display
    let previewData: Data
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: MessageRole
    var text: String
    var images: [AttachedImage] = []
    var timestamp: Date = Date()
}

enum MessageRole: String {
    case user
    case assistant
    case system
}

// MARK: - Provider enum

enum AIProvider: String, CaseIterable, Identifiable {
    case openai     = "openai"
    case claude     = "claude"
    case perplexity = "perplexity"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai:     return "OpenAI GPT"
        case .claude:     return "Claude"
        case .perplexity: return "Perplexity"
        }
    }

    var shortName: String {
        switch self {
        case .openai:     return "GPT"
        case .claude:     return "Claude"
        case .perplexity: return "Pplx"
        }
    }

    var icon: String {
        switch self {
        case .openai:     return "brain.filled.head.profile"
        case .claude:     return "sparkles"
        case .perplexity: return "magnifyingglass.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .openai:     return "#10a37f"
        case .claude:     return "#c96442"
        case .perplexity: return "#5c5ef7"
        }
    }

    var supportsTools: Bool {
        switch self {
        case .openai, .claude: return true
        case .perplexity:      return false
        }
    }
}

// MARK: - Protocol

protocol AIServiceProtocol {
    func chat(
        messages: [ChatMessage],
        context: String?,
        executor: AIToolExecutor?
    ) async throws -> (text: String, toolCalls: [AIToolCall])
}

// MARK: - Keychain helpers

enum KeychainKey {
    static let openAIAPIKey       = "zadachnik.openai.apikey"
    static let claudeAPIKey       = "zadachnik.claude.apikey"
    static let perplexityAPIKey   = "zadachnik.perplexity.apikey"
    static let googleClientId     = "zadachnik.google.clientid"
    static let googleClientSecret = "zadachnik.google.clientsecret"
    static let googleIcalURL      = "zadachnik.google.icalurl"
    static let airtableAPIKey     = "zadachnik.airtable.apikey"
    static let airtableBaseId     = "zadachnik.airtable.baseid"
    static let telegramBotToken   = "zadachnik.telegram.token"
    static let telegramChatId     = "zadachnik.telegram.chatid"
}

enum KeychainHelper {
    static func save(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData:   data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(_ key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - System Prompt Builder

private func buildSystemPrompt(context: String?) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "ru_RU")
    df.dateStyle = .full
    df.timeStyle = .short
    let dateStr = df.string(from: Date())

    var prompt = """
    Ты ИИ-помощник в приложении «Задачник» — персональном менеджере задач, заметок, проектов и контактов.
    Сегодня: \(dateStr).

    ## Инструменты
    - Задачи: list_tasks, search_tasks, create_task, update_task, complete_task, delete_task
    - Заметки: list_notes, create_note, update_note, delete_note, convert_note_to_task
    - Проекты: list_projects, create_project
    - Календарь: add_to_calendar
    - Люди (CRM): list_people, create_person, create_interaction
    - Звонки: list_call_recordings
    - Сводка: get_today_summary

    ## Работа со скриншотами и изображениями
    Когда пользователь присылает изображение (скриншот, фото визитки, переписку, профиль соцсети):
    1. ВНИМАТЕЛЬНО прочитай всё что видно на изображении
    2. Определи тип данных: контакт человека, задача/список дел, заметка, событие и т.д.
    3. БЕЗ ЛИШНИХ ВОПРОСОВ вызови нужный инструмент:
       - Контакт/профиль/визитка → create_person (извлеки имя, должность, компанию, телефон, email, telegram, linkedin)
       - Список задач/todo → create_task для каждого пункта
       - Заметка/текст → create_note
       - Событие/встреча → add_to_calendar
    4. Если на изображении несколько объектов (несколько контактов, несколько задач) — создай все
    5. Добавляй только данные которые ВИДИШЬ на изображении, не придумывай
    6. После создания — скажи что именно добавил, с деталями

    Примеры правильного поведения:
    - Скриншот контакта в телефоне → сразу вызвать create_person с именем и телефоном
    - Фото визитки → create_person с именем, компанией, контактами
    - Скриншот переписки Telegram → create_person (если виден профиль) + create_interaction
    - Фото списка задач → create_task для каждого пункта

    ## Правила
    - Используй инструменты ПРОАКТИВНО — не спрашивай разрешения на безопасные операции (чтение, создание)
    - Перед удалением или массовым изменением — уточни у пользователя
    - Если нужно найти по названию — сначала search_tasks / list_notes / list_people, потом действие с ID
    - Отвечай на русском, кратко и по делу
    - После выполнения — подтверди что сделано с деталями (имя контакта, название задачи и т.п.)
    """

    if let ctx = context, !ctx.isEmpty {
        prompt += "\n\n## Контекст текущего экрана\n\(ctx)"
    }

    return prompt
}

// MARK: - Claude Models

enum ClaudeModel: String, CaseIterable, Identifiable {
    case sonnet46  = "claude-sonnet-4-6"
    case opus46    = "claude-opus-4-6"
    case haiku45   = "claude-haiku-4-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sonnet46: return "Sonnet 4.6"
        case .opus46:   return "Opus 4.6"
        case .haiku45:  return "Haiku 4.5"
        }
    }

    var description: String {
        switch self {
        case .sonnet46: return "Баланс скорости и качества"
        case .opus46:   return "Умнейший, для сложных задач"
        case .haiku45:  return "Быстрый и дешёвый"
        }
    }
}

// MARK: - OpenAI Models

enum OpenAIModel: String, CaseIterable, Identifiable {
    case gpt52codex = "gpt-5.2-codex"
    case gpt52      = "gpt-5.2"
    case gpt52pro   = "gpt-5.2-pro"
    case gpt5mini   = "gpt-5-mini"
    case gpt4o      = "gpt-4o"
    case gpt4omini  = "gpt-4o-mini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt52codex: return "GPT-5.2 Codex"
        case .gpt52:      return "GPT-5.2"
        case .gpt52pro:   return "GPT-5.2 Pro"
        case .gpt5mini:   return "GPT-5 mini"
        case .gpt4o:      return "GPT-4o"
        case .gpt4omini:  return "GPT-4o mini"
        }
    }

    var description: String {
        switch self {
        case .gpt52codex: return "Лучший для кода и агентов"
        case .gpt52:      return "Флагман, лучший для задач"
        case .gpt52pro:   return "Умнее, дороже"
        case .gpt5mini:   return "Быстрый, дешёвый"
        case .gpt4o:      return "Надёжный, проверенный"
        case .gpt4omini:  return "Самый дешёвый"
        }
    }
}

// MARK: - Claude Service (with tool use loop)

struct ClaudeService: AIServiceProtocol {
    private let apiKey: String
    private let model: String

    init(apiKey: String, model: String = ClaudeModel.sonnet46.rawValue) {
        self.apiKey = apiKey
        self.model  = model
    }

    func chat(
        messages: [ChatMessage],
        context: String?,
        executor: AIToolExecutor?
    ) async throws -> (text: String, toolCalls: [AIToolCall]) {
        let tools = AITools.claudeTools
        var collectedToolCalls: [AIToolCall] = []

        // Build initial messages array
        var apiMessages: [[String: Any]] = buildClaudeMessages(from: messages, context: context)
        let systemPrompt = buildSystemPrompt(context: context)

        var iterations = 0
        let maxIterations = 8

        while iterations < maxIterations {
            iterations += 1

            let body: [String: Any] = [
                "model": model,
                "max_tokens": 2048,
                "system": systemPrompt,
                "messages": apiMessages,
                "tools": tools
            ]

            let (data, _) = try await postClaude(body: body)

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIError.parseError("Не удалось разобрать ответ Claude")
            }

            if let errType = json["type"] as? String, errType == "error" {
                let errMsg = (json["error"] as? [String: Any])?["message"] as? String ?? "Ошибка API"
                throw AIError.apiError("Claude: \(errMsg)")
            }

            let stopReason = json["stop_reason"] as? String ?? ""
            let contentBlocks = json["content"] as? [[String: Any]] ?? []

            print("[Claude] iteration=\(iterations) stop_reason=\(stopReason) blocks=\(contentBlocks.count)")

            // Append assistant message to history
            apiMessages.append(["role": "assistant", "content": contentBlocks])

            if stopReason == "tool_use" {
                guard let executor else {
                    // No executor — return whatever text exists
                    break
                }
                // Process all tool calls in this response
                var toolResults: [[String: Any]] = []

                for block in contentBlocks {
                    guard block["type"] as? String == "tool_use",
                          let toolId   = block["id"] as? String,
                          let toolName = block["name"] as? String,
                          let toolArgs = block["input"] as? [String: Any] else { continue }

                    print("[Claude] calling tool: \(toolName) args=\(toolArgs)")
                    let (resultJSON, toolCall) = await executor.execute(name: toolName, args: toolArgs)
                    collectedToolCalls.append(toolCall)

                    toolResults.append([
                        "type": "tool_result",
                        "tool_use_id": toolId,
                        "content": resultJSON
                    ])
                }

                apiMessages.append(["role": "user", "content": toolResults])
                continue
            }

            // Final text response (stop_reason == "end_turn" or "max_tokens")
            let text = contentBlocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return (text.isEmpty ? "Готово." : text, collectedToolCalls)
        }

        throw AIError.apiError("Превышен лимит итераций tool use")
    }

    private func buildClaudeMessages(from messages: [ChatMessage], context: String?) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for msg in messages where msg.role != .system {
            if msg.images.isEmpty {
                result.append(["role": msg.role.rawValue, "content": msg.text])
            } else {
                // Vision: content as array of blocks
                var blocks: [[String: Any]] = []
                for img in msg.images {
                    blocks.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": img.mimeType,
                            "data": img.base64
                        ]
                    ])
                }
                if !msg.text.isEmpty {
                    blocks.append(["type": "text", "text": msg.text])
                }
                result.append(["role": msg.role.rawValue, "content": blocks])
            }
        }

        if result.first?["role"] as? String == "assistant" {
            result.insert(["role": "user", "content": "(начало диалога)"], at: 0)
        }

        return result
    }

    private func postClaude(body: [String: Any]) async throws -> (Data, URLResponse) {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errStr = String(data: data, encoding: .utf8) ?? "Неизвестная ошибка"
            throw AIError.apiError("Claude HTTP: \(errStr)")
        }
        return (data, response)
    }
}

// MARK: - OpenAI Service (with tool use loop)

struct OpenAIService: AIServiceProtocol {
    private let apiKey: String
    private let model: String
    private let allowCompatibilityRetry: Bool

    init(
        apiKey: String,
        model: String = OpenAIModel.gpt52codex.rawValue,
        allowCompatibilityRetry: Bool = true
    ) {
        self.apiKey = apiKey
        self.model  = model
        self.allowCompatibilityRetry = allowCompatibilityRetry
    }

    func chat(
        messages: [ChatMessage],
        context: String?,
        executor: AIToolExecutor?
    ) async throws -> (text: String, toolCalls: [AIToolCall]) {
        let tools = AITools.openAITools
        var collectedToolCalls: [AIToolCall] = []
        let systemPrompt = buildSystemPrompt(context: context)

        var apiMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in messages where msg.role != .system {
            if msg.images.isEmpty {
                apiMessages.append(["role": msg.role.rawValue, "content": msg.text])
            } else {
                var parts: [[String: Any]] = []
                for img in msg.images {
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(img.mimeType);base64,\(img.base64)", "detail": "high"]
                    ])
                }
                if !msg.text.isEmpty {
                    parts.append(["type": "text", "text": msg.text])
                }
                apiMessages.append(["role": msg.role.rawValue, "content": parts])
            }
        }

        var iterations = 0
        let maxIterations = 8

        while iterations < maxIterations {
            iterations += 1

            var body: [String: Any] = [
                "model": model,
                "messages": apiMessages,
                "max_tokens": 2048
            ]
            if executor != nil {
                body["tools"] = tools
                body["tool_choice"] = "auto"
            }

            let (data, response) = try await postOpenAI(
                endpoint: "https://api.openai.com/v1/chat/completions",
                body: body
            )
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let errStr = String(data: data, encoding: .utf8) ?? "Неизвестная ошибка"
                if shouldFallbackToLegacyCompletions(errorBody: errStr) {
                    // First fallback: retry on a known-compatible chat model.
                    if allowCompatibilityRetry && model != OpenAIModel.gpt4omini.rawValue {
                        return try await OpenAIService(
                            apiKey: apiKey,
                            model: OpenAIModel.gpt4omini.rawValue,
                            allowCompatibilityRetry: false
                        ).chat(
                            messages: messages,
                            context: context,
                            executor: executor
                        )
                    }
                    // Second fallback: legacy completions for completion-only models.
                    return try await chatViaLegacyCompletions(messages: messages, context: context)
                }
                throw AIError.apiError("OpenAI: \(errStr)")
            }

            guard let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices  = json["choices"] as? [[String: Any]],
                  let choice   = choices.first,
                  let message  = choice["message"] as? [String: Any] else {
                throw AIError.parseError("Не удалось разобрать ответ OpenAI")
            }

            let finishReason = choice["finish_reason"] as? String ?? ""
            print("[OpenAI] iteration=\(iterations) finish_reason=\(finishReason)")

            if finishReason == "tool_calls", let toolCallsRaw = message["tool_calls"] as? [[String: Any]] {
                guard let executor else { break }

                // Append assistant message with tool_calls
                apiMessages.append(message)

                for tc in toolCallsRaw {
                    guard let tcId   = tc["id"] as? String,
                          let fn     = tc["function"] as? [String: Any],
                          let name   = fn["name"] as? String,
                          let argsStr = fn["arguments"] as? String,
                          let argsData = argsStr.data(using: .utf8),
                          let args   = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else { continue }

                    print("[OpenAI] calling tool: \(name) args=\(args)")
                    let (resultJSON, toolCall) = await executor.execute(name: name, args: args)
                    collectedToolCalls.append(toolCall)

                    apiMessages.append([
                        "role": "tool",
                        "tool_call_id": tcId,
                        "content": resultJSON
                    ])
                }
                continue
            }

            let text = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (text.isEmpty ? "Готово." : text, collectedToolCalls)
        }

        throw AIError.apiError("Превышен лимит итераций tool use")
    }

    private func chatViaLegacyCompletions(
        messages: [ChatMessage],
        context: String?
    ) async throws -> (text: String, toolCalls: [AIToolCall]) {
        let systemPrompt = buildSystemPrompt(context: context)
        let transcript = messages
            .filter { $0.role != .system }
            .map { msg -> String in
                switch msg.role {
                case .user: return "Пользователь: \(msg.text)"
                case .assistant: return "Ассистент: \(msg.text)"
                case .system: return ""
                }
            }
            .joined(separator: "\n\n")

        let prompt = """
        \(systemPrompt)

        \(transcript)

        Ассистент:
        """

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "max_tokens": 1024,
            "temperature": 0.3
        ]

        let (data, response) = try await postOpenAI(
            endpoint: "https://api.openai.com/v1/completions",
            body: body
        )
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errStr = String(data: data, encoding: .utf8) ?? "Неизвестная ошибка"
            throw AIError.apiError("OpenAI completions: \(errStr)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first else {
            throw AIError.parseError("Не удалось разобрать ответ OpenAI completions")
        }

        let text = ((first["text"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty ? "Готово." : text, [])
    }

    private func postOpenAI(
        endpoint: String,
        body: [String: Any]
    ) async throws -> (Data, URLResponse) {
        guard let url = URL(string: endpoint) else {
            throw AIError.networkError("Некорректный URL OpenAI")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180
        return try await URLSession.shared.data(for: request)
    }

    private func shouldFallbackToLegacyCompletions(errorBody: String) -> Bool {
        let lower = errorBody.lowercased()
        if lower.contains("not a chat model") { return true }
        if lower.contains("chat/completions endpoint") { return true }
        if lower.contains("did you mean to use v1/completions") { return true }
        if lower.contains("v1/completions") && lower.contains("invalid_request_error") && lower.contains("\"param\":\"model\"") {
            return true
        }
        return false
    }
}

// MARK: - Perplexity Service (no tools)

struct PerplexityService: AIServiceProtocol {
    private let apiKey: String
    private let model = "sonar-pro"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func chat(
        messages: [ChatMessage],
        context: String?,
        executor: AIToolExecutor?
    ) async throws -> (text: String, toolCalls: [AIToolCall]) {
        let url = URL(string: "https://api.perplexity.ai/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var apiMessages: [[String: String]] = [
            ["role": "system", "content": buildSystemPrompt(context: context)]
        ]
        for msg in messages where msg.role != .system {
            apiMessages.append(["role": msg.role.rawValue, "content": msg.text])
        }

        let body: [String: Any] = [
            "model": model,
            "messages": apiMessages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errStr = String(data: data, encoding: .utf8) ?? "Неизвестная ошибка"
            throw AIError.apiError("Perplexity: \(errStr)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard let text = message?["content"] as? String else {
            throw AIError.parseError("Не удалось прочитать ответ Perplexity")
        }
        return (text, [])
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case noAPIKey(String)
    case networkError(String)
    case apiError(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let p):     return "API ключ для \(p) не указан в Настройках"
        case .networkError(let m): return m
        case .apiError(let m):     return m
        case .parseError(let m):   return m
        }
    }
}

// MARK: - AI Manager

@MainActor
final class AIManager: ObservableObject {
    static let shared = AIManager()

    @Published var selectedProvider: AIProvider = .claude
    @Published var selectedClaudeModel: ClaudeModel = .sonnet46
    @Published var selectedOpenAIModel: OpenAIModel = .gpt52codex
    @Published var isLoading = false
    @Published var lastError: String?

    var currentTask: Task<Void, Never>?

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "ai.selectedProvider"),
           let provider = AIProvider(rawValue: raw) {
            selectedProvider = provider
        }
        if let raw = UserDefaults.standard.string(forKey: "ai.claudeModel"),
           let model = ClaudeModel(rawValue: raw) {
            selectedClaudeModel = model
        }
        if let raw = UserDefaults.standard.string(forKey: "ai.openaiModel"),
           let model = OpenAIModel(rawValue: raw) {
            selectedOpenAIModel = model
        }
    }

    func setProvider(_ provider: AIProvider) {
        selectedProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "ai.selectedProvider")
    }

    func setClaudeModel(_ model: ClaudeModel) {
        selectedClaudeModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "ai.claudeModel")
    }

    func setOpenAIModel(_ model: OpenAIModel) {
        selectedOpenAIModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "ai.openaiModel")
    }

    /// Returns (assistantText, toolCalls performed during this request)
    func chat(
        messages: [ChatMessage],
        context: String? = nil,
        executor: AIToolExecutor? = nil
    ) async -> (text: String?, toolCalls: [AIToolCall]) {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let service = try makeService()
            // Run network request off main thread to avoid UI freeze
            let result = try await Task.detached(priority: .userInitiated) {
                try await service.chat(
                    messages: messages,
                    context: context,
                    executor: executor
                )
            }.value
            return (result.text, result.toolCalls)
        } catch is CancellationError {
            return (nil, [])
        } catch {
            lastError = error.localizedDescription
            return (nil, [])
        }
    }

    // MARK: - Meeting Summary

    /// Generates structured meeting summary from transcript using the currently selected AI provider.
    /// Returns a MeetingSummary with topic, agreements, and action items.
    func summarizeMeeting(transcript: String) async throws -> MeetingSummary {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.apiError("Транскрипция пустая")
        }

        let service = try makeService()
        let prompt = """
        Ты помощник для структурирования переговоров. \
        Проанализируй транскрипцию и верни ТОЛЬКО JSON без лишнего текста:
        {"topic": "краткая тема разговора", "agreements": ["договорённость 1", "договорённость 2"], "actions": ["действие 1", "действие 2"]}
        Если договорённостей или действий нет — верни пустой массив [].
        Транскрипция: \(transcript)
        """

        let messages = [ChatMessage(role: .user, text: prompt)]
        let (text, _) = try await service.chat(messages: messages, context: "", executor: nil)

        // Extract JSON from response (model may add extra text)
        let jsonString: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            jsonString = String(text[start...end])
        } else {
            throw AIError.parseError("Не удалось получить JSON от ИИ")
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw AIError.parseError("Ошибка кодирования JSON")
        }

        let summary = try JSONDecoder().decode(MeetingSummary.self, from: data)
        NSLog("[AIManager] summarizeMeeting OK: topic='\(summary.topic)' agreements=\(summary.agreements.count) actions=\(summary.actions.count)")
        return summary
    }

    private func makeService() throws -> AIServiceProtocol {
        switch selectedProvider {
        case .openai:
            guard let key = KeychainHelper.load(KeychainKey.openAIAPIKey), !key.isEmpty else {
                throw AIError.noAPIKey("OpenAI")
            }
            return OpenAIService(apiKey: key, model: selectedOpenAIModel.rawValue)
        case .claude:
            guard let key = KeychainHelper.load(KeychainKey.claudeAPIKey), !key.isEmpty else {
                throw AIError.noAPIKey("Claude")
            }
            return ClaudeService(apiKey: key, model: selectedClaudeModel.rawValue)
        case .perplexity:
            guard let key = KeychainHelper.load(KeychainKey.perplexityAPIKey), !key.isEmpty else {
                throw AIError.noAPIKey("Perplexity")
            }
            return PerplexityService(apiKey: key)
        }
    }
}
