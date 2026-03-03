# PARAMS.md — Задачник

## Bundle & Identity

| Параметр | Значение |
|---|---|
| Bundle ID | `com.cek.zadachnik` |
| iCloud Container | `iCloud.com.cek.zadachnik` |
| Display Name | `Задачник` |
| Version | `1.0` (build 1) |

## Deployment Targets

| Платформа | Минимальная версия |
|---|---|
| iOS | 17.0 |
| macOS | 14.0 (Sonoma) |

## SwiftData Schema

| Модель | Поля | Связи |
|---|---|---|
| `Project` | id, name, colorHex, icon, sortOrder, createdAt, kanbanColumns | → [TaskItem] (cascade delete) |
| `TaskItem` | id, title, notes, priorityRaw, statusRaw, kanbanColumn, dueDate, estimatedMinutes, sortOrder, createdAt, completedAt, **tags, linkedPersonId** | → Project |
| `QuickNote` | id, body, **title, tags**, createdAt, isPinned, deadline, deadlineIncludesTime, calendarEventId, convertedToTask | — |
| `Person` | id, name, role, company, email, phone, categoryTags, notes, colorHex, createdAt | → introducer: Person?, → [Interaction] (cascade delete) |
| `Interaction` | id, date, typeRaw, notes, result | → Person |
| `Deal` | id, title, notes, percent, amount, currency, dueDate, statusRaw, createdAt, personId, documentLinks, processDates, updates, recurringEnabled, recurrenceIntervalRaw, recurrenceCustomDays, calendarSyncEnabled, calendarEventId | — |
| `MaterialLink` | id, url, title, previewText, typeRaw, tags, createdAt | — |
| `RecurringPattern` | id, title, notes, intervalRaw, customDays, nextDate, isActive, createdAt, lastTriggeredAt | — |
| `CustomField` | id, name, typeRaw, selectOptions, sortOrder, createdAt | — |
| `CustomFieldValue` | id, fieldId, taskId, textValue, numberValue, dateValue, boolValue, updatedAt | — |
| `VoiceMemo` | id, fileName, duration, transcription, createdAt, isCallRecording, linkedNoteId, linkedTaskId | — |
| `Attachment` | id, fileName, mimeType, fileSize, createdAt, linkedTaskId, linkedNoteId | — |

## InteractionType (Interaction.typeRaw)

| Значение | Смысл |
|---|---|
| `meeting` | Встреча |
| `call` | Звонок |
| `message` | Сообщение |
| `email` | Email |
| `coffee` | Кофе |
| `event` | Мероприятие |
| `misunderstanding` | Недопонимание |
| `conflict` | Конфликт |
| `sorry` | Извинение |
| `other` | Другое |

## Константы моделей

### Priority (TaskItem.priorityRaw)
| Значение | Смысл | Цвет |
|---|---|---|
| 0 | Нет | #8E8E93 (серый) |
| 1 | Низкий | #007AFF (синий) |
| 2 | Средний | #FF9500 (оранжевый) |
| 3 | Высокий | #FF3B30 (красный) |

### TaskStatus (TaskItem.statusRaw)
| Значение | Смысл |
|---|---|
| 0 | К выполнению (todo) |
| 1 | В работе (inProgress) |
| 2 | Выполнено (done) |

### Kanban Columns (Project.kanbanColumns, по умолчанию)
```
["todo", "inProgress", "review", "done"]
```

### Палитра цветов проектов
```
#4F8EF7, #FF6B6B, #4ECDC4, #FFD93D, #6BCB77, #C77DFF, #FF9F43, #A0C4FF
```

### Оценка времени (estimatedMinutes — варианты меню)
```
0, 15, 30, 45, 60, 90, 120, 180, 240, 360, 480 минут
```

## iCloud / CloudKit

- Синхронизация через SwiftData `.cloudKitDatabase: .automatic`
- Требует: платный Apple Developer Account ($99/год)
- Container: `iCloud.com.cek.zadachnik`
- Fallback: локальное SQLite хранилище при недоступности CloudKit
- Entitlements: `Задачник/Zadachnik.entitlements`

## Горячие клавиши (macOS)

| Действие | Шорткат |
|---|---|
| Быстрая запись | ⌘⇧N |
| Новый элемент | ⌘N |

## Файлы проекта

| Файл | Назначение |
|---|---|
| `project.yml` | XcodeGen спецификация (источник истины для xcodeproj) |
| `Задачник.xcodeproj` | Генерируется через xcodegen, не редактировать вручную |
| `Задачник/Zadachnik.entitlements` | iCloud + CloudKit entitlements |

## Внешние сервисы

| Сервис | Ключ Keychain | Описание |
|---|---|---|
| OpenAI | `zadachnik.openai.apikey` | GPT-4o для AI-ассистента |
| Claude | `zadachnik.claude.apikey` | Claude 3.5 Sonnet |
| Perplexity | `zadachnik.perplexity.apikey` | Perplexity поиск |
| Airtable API | `zadachnik.airtable.apikey` | pat... токен |
| Airtable Base | `zadachnik.airtable.baseid` | `appyzFVX3fyUhi24q` |
| Airtable Table | — | `tbln9PpniXqz43sTj` (Project management 2026) |
| Telegram Token | `zadachnik.telegram.token` | Bot token от @BotFather |
| Telegram Chat | `zadachnik.telegram.chatid` | `-5274419536` |
| Google Cal iCal | `zadachnik.google.icalurl` | Приватная ссылка .ics |

### Airtable
- Base: `https://airtable.com/appyzFVX3fyUhi24q`
- Таблица: `Project management 2026` (tbln9PpniXqz43sTj)
- View (UI): `viwAKbyTaVUDkumEp` (используется для просмотра, импорт читает всю таблицу)
- Docs: https://airtable.com/developers/web/api/introduction

### Airtable Sync Safety
- Режимы запуска: `dryRun=true|false`
- Конфликты: `preferRemote | preferLocal | skip`
- Авто-удаление: выключено (missing записи только репортятся)
- Retry policy API: повторы для `429` и `5xx` (экспоненциальная задержка + `Retry-After`)
- Ключ сопоставления: `TaskItem.airtableId <-> Airtable record id`
- Журнал запусков: последние 40 запусков sync (режим, план, результат, ошибки)
- Экспорт журнала: `airtable-sync-history-*.json|csv` в папку Downloads (fallback Documents)
- Источник `modifiedAt` для sync: поле Airtable `Last modified time` (или аналоги `Last Modified/Дата изменения/Последнее изменение`), fallback `createdTime`
- Хранение журнала: in-memory (очищается после перезапуска приложения), для аудита использовать экспорт JSON/CSV

### Telegram
- Создать бота: https://t.me/BotFather
- Chat ID: `/getUpdates` после отправки сообщения боту
- API docs: https://core.telegram.org/bots/api#sendmessage

### Google Calendar iCal
- Настройки → Мои календари → ⋮ → Настройки и общий доступ → Приватный адрес в формате iCal
- Формат: `https://calendar.google.com/calendar/ical/{email}/private-{hash}/basic.ics`

## Документация

- SwiftData: https://developer.apple.com/documentation/swiftdata
- CloudKit + SwiftData: https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices
- XcodeGen: https://github.com/yonaskolb/XcodeGen
- g3 (AI coding agent): https://github.com/dhanji/g3

## G3 параметры работы в проекте

| Параметр | Значение |
|---|---|
| Режим | `accumulative autonomous mode` (по умолчанию при запуске `g3`) |
| Команда запуска | `g3` в корне проекта |
| Формат требований | `requirement> ...` |
| Стратегия итераций | 1 логическое изменение на шаг |
| Пост-проверка | просмотр diff + запуск в Xcode после каждой итерации |

### G3 workflow checklist
- Запускать из корня: `/Users/cek/Desktop/Задачник`
- Перед большой итерацией делать snapshot
- После каждого шага актуализировать `PARAMS.md` при изменении параметров/лимитов
- Полезные выводы и паттерны переносить в `LESSONS.md`
