# Functional Spec — Задачник

Этот документ фиксирует текущую реализацию проекта и служит опорой при изменении функций, моделей и интеграций.

## 1) Назначение приложения

`Задачник` — SwiftUI-приложение для личного управления задачами и CRM-активностями:
- задачи, проекты, канбан, таймлайн;
- быстрые заметки, теги, глобальный поиск;
- люди, взаимодействия, договорённости;
- материалы, файлы, голосовые;
- интеграции с AI, Airtable, Telegram, системным календарём (EventKit).

## 2) Техническая архитектура

- **UI:** SwiftUI (`Views/*`)
- **Данные:** SwiftData (`@Model` классы в `Models/*`)
- **Хранилище:** файл `zadachnik.store` в `Application Support/Zadachnik`
- **Интеграции:** сервисы в `Services/*`
- **Ключи:** Keychain (`KeychainHelper` в `Services/AIService.swift`)
- **Точка входа:** `Задачник/App/ZadachnikApp.swift`

Ключевые уровни:
1. `Views` читают/изменяют модели через `@Query`, `@Environment(\.modelContext)`.
2. `Models` содержат доменные поля + вычисляемые свойства.
3. `Services` выполняют сеть/интеграции и возвращают ошибки через `LocalizedError`.

## 3) Навигация и экраны

Главный контейнер: `Задачник/Views/ContentView.swift`.

- **macOS:** `NavigationSplitView` + sidebar + detail + optional AI sidebar.
- **iOS:** `TabView` (`Сегодня`, `Проекты`, `Люди`, `Заметки`, `Ещё`).

Основные экраны:
- `TodayView` — агрегатор просроченных/сегодня/завтра, фильтр по тегам, сортировка.
- `ProjectDetailView` — режимы `Список` / `Канбан` / `Таймлайн`, inline quick-add задачи, дедлайн проекта.
- `TaskDetailView` — полная форма задачи (статус, приоритет, классификация, даты, флаги, кастомные поля).
- `QuickNotesView` — заметки с тегами.
- `PeopleView`/`PersonDetailView` — контакты и история взаимодействий.
- `DealsView`/`DealDetailView` — договорённости со статусом и прогрессом.
- `MaterialsView` — ссылки/файлы/материалы.
- `VoiceMemosView` — записи и транскрипция.
- `AttachmentsView` — файловое хранилище.
- `GlobalSearchView` — единый поиск по всем сущностям.
- `AppSettingsView` — ключи интеграций, импорт и настройки.

## 4) Модель данных (источник изменений)

Модели находятся в `Задачник/Models/*`.

### 4.1 `TaskItem` (центральная сущность)
- Core поля: `title`, `notes`, `taskResult`, `resourcesUsed`, `monthlyResults`, `linkURL`.
- Управление: `priorityRaw`, `statusRaw`, `completionPercent`, `taggedOnTask`.
- Классификация: `airtableProjects`, `directionRaw`, `typeRaw`, `responsibles`.
- Даты: `startDate`, `midCheckDate`, `deadline`.
- Флаги: `bringToMeetingRaw`, `top1Raw`.
- Локальные поля: `tags`, `kanbanColumn`, `estimatedMinutes`, `linkedPersonId`.
- Связи/интеграции: `project`, `airtableId`, `airtableUpdatedAt`, `googleCalendarEventId`.

Вычисляемая логика:
- `priority`, `status`, `direction`, `taskType`, `bringToMeeting`, `top1` — преобразования raw <-> enum.
- При `status = .done` автоматически ставится `completedAt`, иначе сбрасывается.
- `dueDate` является алиасом `deadline`.
- `isOverdue`, `isDueToday`, `isDueTomorrow`, `overdueDays`.
- `importanceScore = priorityRaw * 3 + min(overdueDays * 2, 20) + todayBonus(5)`.

### 4.2 Прочие модели
- `Project` — проект, цвет, иконка, канбан-колонки, дедлайн, `googleCalendarEventId`, связь с задачами (cascade delete).
- `QuickNote` — текстовая заметка (`body`, `title`, `tags`, `isPinned`, `deadline`, `deadlineIncludesTime`, `calendarEventId`, `convertedToTask`).
- `Person` — контакт + `introducer` + список `Interaction`.
- `Interaction` — запись взаимодействия (`typeRaw`, `notes`, `result`).
- `Deal` — договорённость (`percent`, `amount`, `currency`, `statusRaw`, `personId`).
- `MaterialLink` — материал (`url`, `title`, `previewText`, `typeRaw`, `tags`).
- `RecurringPattern` — повторяемый ритуал (`intervalRaw`, `customDays`, `nextDate`, `isActive`).
- `CustomField` — схема кастомного поля задачи.
- `CustomFieldValue` — значение кастомного поля для конкретной задачи.
- `VoiceMemo` — голосовая запись (файл, длительность, транскрипция, связи с note/task).
- `Attachment` — вложенный файл и связи с task/note/person/project.

## 5) Enum-справочник (критично для совместимости)

- `Priority`: `none, low, medium, high, critical, top` (0...5)
- `TaskStatus`: `Надо сделать`, `В работе`, `Готово`, `Заблокировано`, `На проверке`
- `TaskDirection`: `Продукт`, `Маркетинг`, `Операционка`, `Финансы`, `HR`, `Продажи`, `Разработка`, `Другое`
- `TaskType`: `Операционка`, `Развитие`
- `MeetingFlag`: `Да/Нет`
- `Top1Flag`: `Да/Нет`
- `InteractionType`: `meeting`, `call`, `message`, `email`, `coffee`, `event`, `misunderstanding`, `conflict`, `sorry`, `other`
- `DealStatus`: `active`, `completed`, `cancelled`, `paused`
- `MaterialType`: `link`, `file`, `image`, `note`
- `RecurringInterval`: `daily`, `weekly`, `monthly`, `custom`
- `CustomFieldType`: `text`, `number`, `date`, `select`, `toggle`

Важно: изменения `rawValue` у enum ломают фильтры, сохранённые данные и синхронизацию с внешними сервисами.

## 6) Интеграции и сервисы

### 6.1 AI (`Services/AIService.swift`)
- Провайдеры: OpenAI, Claude, Perplexity.
- Менеджер: `AIManager.shared`.
- Ключи: Keychain (`zadachnik.*`).
- Ошибки: `AIError`.

### 6.2 Airtable (`Services/AirtableService.swift`)
- Таблица задач: `Project management 2026`.
- Ключевые методы: `fetchRecords`, `pushTask`, `pullTasks`, `syncAll`, `validateConnection`.
- Важно: маппинг полей задаётся в enum `F` внутри сервиса.

### 6.3 Telegram (`Services/TelegramService.swift`)
- Сообщения через bot API `sendMessage`.
- Методы: `send`, `sendError`, `sendTaskReminder`, `validateConnection`.

### 6.4 Calendar / EventKit (`Services/CalendarService.swift`)
- Авторизация и выбор календаря.
- Создание/обновление событий: `createOrUpdateEvent`.
- Удаление: `deleteEvent`.
- Используется в `TaskDetailView` и `ProjectDetailView`.

### 6.5 Voice (`Services/VoiceRecorderService.swift`)
- Запись (`startRecording`/`stopRecording`), воспроизведение, транскрипция через `SFSpeechRecognizer`.
- Файлы в `Documents/VoiceMemos`.

## 7) Функциональные правила (бизнес-логика)

- Невыполненные задачи фильтруются по `statusRaw != "Готово"` в `TodayView`.
- В `TodayView` секции собираются по `isOverdue / isDueToday / isDueTomorrow`.
- В `ProjectDetailView` quick-add создаёт задачу с `sortOrder = project.tasks.count`.
- В `TaskDetailView` сохранение:
  - обновляет существующую задачу или создаёт новую;
  - сохраняет `CustomFieldValue`;
  - может синхронизировать задачу в Airtable;
  - может создать/обновить событие календаря.
- Глобальный drag-and-drop файлов в `ContentView` импортирует файлы в `Attachment`.

## 8) Матрица влияния изменений

Используйте как чек-лист перед рефакторингом.

### Изменение полей `TaskItem`
Проверьте:
- `TaskDetailView` (load/save формы),
- `TaskCard`, `TodayView`, `ProjectDetailView`, `KanbanView`, `TimelineView`,
- `GlobalSearchView`,
- `AirtableService.buildFields/applyRecord/AirtableRecord`,
- `PARAMS.md` (описание схемы).

### Изменение `TaskStatus`/`Priority`/других enum
Проверьте:
- UI picker-ы и фильтры (`TodayView`, `TaskDetailView`),
- вычисления (`importanceScore`, `isOverdue`),
- внешние маппинги (Airtable).

### Изменение модели `Project`
Проверьте:
- `ProjectsListView`, `ProjectDetailView`, `ProjectRow`,
- дедлайны и календарную синхронизацию в проекте,
- каскадное удаление задач.

### Изменение интеграций (Airtable/Telegram/AI/Calendar)
Проверьте:
- `AppSettingsView`,
- соответствующий сервис в `Services/*`,
- ключи Keychain (`KeychainKey`),
- текст ошибок для пользователя.

### Изменение `Attachment`/`VoiceMemo`
Проверьте:
- `AttachmentsView`, `AttachmentSection`,
- директории `Documents/Attachments` и `Documents/VoiceMemos`,
- импорт файлов в `ContentView`.

## 9) Процедура безопасного изменения функций/данных

Рекомендуемый порядок:
1. Сделать snapshot/backup.
2. Изменить модель или функцию в одном месте.
3. Найти все вхождения символа (`rg`) и обновить зависимые экраны/сервисы.
4. Если обнаружена ошибка — исправить её автоматически в этом же цикле изменений, не откладывая до отдельного согласования.
5. Обновить документацию (`PARAMS.md` + этот файл).
6. Прогнать ручные сценарии:
   - создание/редактирование задачи;
   - завершение задачи (`status = Готово`);
   - поиск по изменённому полю;
   - синхронизация Airtable (если затронуто);
   - добавление в календарь (если затронуто).

## 10) Известные риски и ограничения

- В `ZadachnikApp.seedKeychainIfNeeded()` присутствуют захардкоженные секреты/токены.  
  Рекомендуется убрать их из кода и загружать только из безопасного источника.
- Часть операций сохраняется через `try?` без явной обработки ошибок — возможны тихие сбои.
- Некоторые вычисления завязаны на строковые `rawValue`; не менять без миграции.

## 11) Связанные документы

- Базовое описание проекта: `README.md`
- Параметры и схема: `PARAMS.md`
