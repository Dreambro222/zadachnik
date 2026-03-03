import Foundation

// MARK: - Tool definitions for Claude and OpenAI function calling

enum AITools {

    // MARK: - All tools (combined list)

    static func allTools(for provider: AIProvider) -> [[String: Any]] {
        switch provider {
        case .claude:     return claudeTools
        case .openai:     return openAITools
        case .perplexity: return []  // Perplexity does not support function calling
        }
    }

    // MARK: - Claude format (tools array)

    static let claudeTools: [[String: Any]] = tools.map { tool in
        [
            "name": tool.name,
            "description": tool.description,
            "input_schema": [
                "type": "object",
                "properties": tool.properties,
                "required": tool.required
            ] as [String: Any]
        ]
    }

    // MARK: - OpenAI format (tools array)

    static let openAITools: [[String: Any]] = tools.map { tool in
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": [
                    "type": "object",
                    "properties": tool.properties,
                    "required": tool.required
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    // MARK: - Tool definitions

    private struct ToolDef {
        let name: String
        let description: String
        let properties: [String: Any]
        let required: [String]
    }

    private static let tools: [ToolDef] = [

        // ── TASKS ──────────────────────────────────────────────────────────

        ToolDef(
            name: "list_tasks",
            description: "Получить список задач. Можно фильтровать по проекту, статусу, дате. Используй для ответов на вопросы 'какие задачи', 'что на сегодня', 'что просрочено'.",
            properties: [
                "filter": prop("string", "Фильтр: 'today' (на сегодня), 'overdue' (просроченные), 'all' (все активные)", enum: ["today", "overdue", "all"]),
                "project_name": prop("string", "Название проекта для фильтрации (опционально)"),
                "status": prop("string", "Статус задачи", enum: ["Надо сделать", "В работе", "Готово", "Заблокировано", "На проверке"]),
                "limit": prop("integer", "Максимальное количество задач в ответе (по умолчанию 20)")
            ],
            required: []
        ),

        ToolDef(
            name: "search_tasks",
            description: "Поиск задач по тексту в названии или описании.",
            properties: [
                "query": prop("string", "Текст для поиска")
            ],
            required: ["query"]
        ),

        ToolDef(
            name: "create_task",
            description: "Создать новую задачу. Используй когда пользователь просит добавить, создать задачу или записать что-то сделать.",
            properties: [
                "title": prop("string", "Название задачи (кратко)"),
                "notes": prop("string", "Описание задачи (опционально)"),
                "priority": prop("integer", "Приоритет: 0=нет, 1=низкий, 2=средний, 3=высокий, 4=критический, 5=топ", enum: [0, 1, 2, 3, 4, 5]),
                "deadline": prop("string", "Дедлайн в формате ISO 8601 (например '2026-03-01T18:00:00')"),
                "project_name": prop("string", "Название проекта (опционально, если не указан — задача без проекта)"),
                "tags": prop("array", "Список тегов (опционально)", items: "string"),
                "add_to_calendar": prop("boolean", "Добавить событие в Календарь с датой дедлайна")
            ],
            required: ["title"]
        ),

        ToolDef(
            name: "update_task",
            description: "Изменить существующую задачу. Перед вызовом узнай ID задачи через list_tasks или search_tasks.",
            properties: [
                "task_id": prop("string", "UUID задачи"),
                "title": prop("string", "Новое название (опционально)"),
                "notes": prop("string", "Новое описание (опционально)"),
                "priority": prop("integer", "Новый приоритет 0–5", enum: [0, 1, 2, 3, 4, 5]),
                "status": prop("string", "Новый статус", enum: ["Надо сделать", "В работе", "Готово", "Заблокировано", "На проверке"]),
                "deadline": prop("string", "Новый дедлайн ISO 8601"),
                "tags": prop("array", "Новые теги", items: "string"),
                "completion_percent": prop("integer", "Процент выполнения 0–100")
            ],
            required: ["task_id"]
        ),

        ToolDef(
            name: "complete_task",
            description: "Отметить задачу как выполненную.",
            properties: [
                "task_id": prop("string", "UUID задачи")
            ],
            required: ["task_id"]
        ),

        ToolDef(
            name: "delete_task",
            description: "Удалить задачу безвозвратно. Используй только если пользователь явно просит удалить.",
            properties: [
                "task_id": prop("string", "UUID задачи")
            ],
            required: ["task_id"]
        ),

        // ── NOTES ──────────────────────────────────────────────────────────

        ToolDef(
            name: "list_notes",
            description: "Получить список заметок. Можно фильтровать по тегу или искать по тексту.",
            properties: [
                "tag": prop("string", "Фильтр по тегу (опционально)"),
                "search": prop("string", "Поиск по тексту заметки (опционально)"),
                "limit": prop("integer", "Максимальное количество (по умолчанию 20)")
            ],
            required: []
        ),

        ToolDef(
            name: "create_note",
            description: "Создать новую заметку.",
            properties: [
                "title": prop("string", "Заголовок заметки (опционально)"),
                "body": prop("string", "Текст заметки"),
                "tags": prop("array", "Теги", items: "string")
            ],
            required: ["body"]
        ),

        ToolDef(
            name: "update_note",
            description: "Обновить существующую заметку.",
            properties: [
                "note_id": prop("string", "UUID заметки"),
                "title": prop("string", "Новый заголовок (опционально)"),
                "body": prop("string", "Новый текст (опционально)"),
                "tags": prop("array", "Новые теги (опционально)", items: "string")
            ],
            required: ["note_id"]
        ),

        ToolDef(
            name: "delete_note",
            description: "Удалить заметку безвозвратно.",
            properties: [
                "note_id": prop("string", "UUID заметки")
            ],
            required: ["note_id"]
        ),

        ToolDef(
            name: "convert_note_to_task",
            description: "Конвертировать заметку в задачу.",
            properties: [
                "note_id": prop("string", "UUID заметки"),
                "task_title": prop("string", "Название задачи (если пусто — используется заголовок заметки)")
            ],
            required: ["note_id"]
        ),

        // ── PROJECTS ───────────────────────────────────────────────────────

        ToolDef(
            name: "list_projects",
            description: "Получить список всех проектов с количеством задач.",
            properties: [:],
            required: []
        ),

        ToolDef(
            name: "create_project",
            description: "Создать новый проект.",
            properties: [
                "name": prop("string", "Название проекта"),
                "color": prop("string", "Цвет в HEX (например #FF6B6B). Если не указан — выбирается автоматически."),
                "icon": prop("string", "SF Symbol иконка (например folder.fill, star.fill)")
            ],
            required: ["name"]
        ),

        // ── CALENDAR ───────────────────────────────────────────────────────

        ToolDef(
            name: "add_to_calendar",
            description: "Добавить событие в системный Календарь (синхронизируется с Google Calendar).",
            properties: [
                "title": prop("string", "Название события"),
                "date": prop("string", "Дата и время в ISO 8601"),
                "end_date": prop("string", "Время окончания в ISO 8601 (опционально, по умолчанию +1 час)"),
                "notes": prop("string", "Заметки к событию (опционально)"),
                "all_day": prop("boolean", "Событие на весь день")
            ],
            required: ["title", "date"]
        ),

        // ── PEOPLE ─────────────────────────────────────────────────────────

        ToolDef(
            name: "list_people",
            description: "Получить список людей из CRM.",
            properties: [
                "search": prop("string", "Поиск по имени или компании (опционально)")
            ],
            required: []
        ),

        ToolDef(
            name: "create_person",
            description: """
            Добавить нового человека в CRM-базу контактов.
            Используй когда пользователь присылает скриншот контакта, визитку, переписку или просит добавить человека.
            Извлеки из изображения/текста: имя, должность, компанию, телефон, email, Telegram, LinkedIn, Instagram.
            Не изобретай данные — добавляй только то что видно на скриншоте.
            """,
            properties: [
                "name":             prop("string", "Полное имя"),
                "role":             prop("string", "Должность / роль (опционально)"),
                "company":          prop("string", "Компания / организация (опционально)"),
                "phone":            prop("string", "Номер телефона (опционально)"),
                "email":            prop("string", "Email (опционально)"),
                "telegram":         prop("string", "Telegram username без @ (опционально)"),
                "notes":            prop("string", "Заметки / дополнительная информация (опционально)"),
                "tags":             prop("array", "Категории/теги (напр. инвестор, партнёр)", items: "string"),
                "source":           prop("string", "Источник знакомства", enum: ["real_life", "telegram", "linkedin", "twitter", "instagram", "email", "event", "other"]),
                "meeting_place":    prop("string", "Место знакомства (опционально)")
            ],
            required: ["name"]
        ),

        ToolDef(
            name: "create_interaction",
            description: "Записать взаимодействие с человеком (встреча, звонок, сообщение и т.д.).",
            properties: [
                "person_name": prop("string", "Имя человека (поиск по базе)"),
                "type": prop("string", "Тип взаимодействия", enum: ["meeting", "call", "message", "email", "coffee", "event", "misunderstanding", "conflict", "sorry", "other"]),
                "notes": prop("string", "Описание взаимодействия"),
                "result": prop("string", "Результат (опционально)")
            ],
            required: ["person_name", "type"]
        ),

        // ── CALL RECORDINGS ────────────────────────────────────────────────

        ToolDef(
            name: "list_call_recordings",
            description: "Получить список записей звонков с транскрипциями. Используй когда пользователь спрашивает о звонках, записях разговоров, что обсуждалось на звонке.",
            properties: [
                "caller_name": prop("string", "Фильтр по имени собеседника (опционально)"),
                "source": prop("string", "Фильтр по типу: telegram, zoom, phone, other (опционально)", enum: ["telegram", "zoom", "phone", "microphone", "other"]),
                "limit": prop("integer", "Максимальное количество записей (по умолчанию 10)")
            ],
            required: []
        ),

        // ── SYSTEM ─────────────────────────────────────────────────────────

        ToolDef(
            name: "get_today_summary",
            description: "Получить сводку на сегодня: задачи на сегодня, просроченные, задачи в работе. Используй в начале разговора или когда пользователь спрашивает 'что у меня сегодня'.",
            properties: [:],
            required: []
        )
    ]

    // MARK: - Helpers

    private static func prop(
        _ type: String,
        _ description: String,
        enum enumValues: [Any]? = nil,
        items itemType: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "type": type,
            "description": description
        ]
        if let enumValues { result["enum"] = enumValues }
        if let itemType, type == "array" {
            result["items"] = ["type": itemType]
        }
        return result
    }
}
