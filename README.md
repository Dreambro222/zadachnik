# Задачник

Нативное SwiftUI приложение для управления задачами на macOS и iPhone с iCloud синхронизацией.

## Возможности

### Задачи и проекты
- **Быстрая запись** — ⌘⇧N на Mac, кнопка + на iPhone. Сохраняй мысль в 1 нажатие
- **Сегодня** — агрегированный вид: все просроченные, сегодняшние и завтрашние задачи с автосортировкой по важности (score = priority × 3 + overdue × 2)
- **Проекты** — раздел с проектами. У каждого — свой цвет и иконка
- **Три вида проекта:** Список | Канбан | Таймлайн
- **Сортировки** — по дате, приоритету, важности, названию
- **Хештеги** — теги на задачах и заметках, фильтрация по тегу
- **Кастомные поля** — добавляй поля (текст, число, дата, выбор, переключатель) в задачи
- **Поиск** — глобальный поиск по всему приложению
- **Заметки с закреплением** — важные заметки можно pin-ить, они всегда сверху списка

### ИИ-помощник
- **ИИ-панель** — боковой чат с Claude или Perplexity прямо в приложении
- **Выбор провайдера** — Claude (структурирование), Perplexity (поиск в интернете)
- **Контекст** — ИИ видит текущую открытую заметку или задачу

### Голос и медиа
- **Голосовые записи** — запись с микрофона, воспроизведение, автотранскрибация через SFSpeechRecognizer
- **Файлы** — загрузка документов, фото, PDF с просмотром через QuickLook
- **Поделиться** — отправка задач и заметок через Share Sheet (Telegram, Email, AirDrop...)

### Люди (CRM)
- История взаимодействий: встреча / звонок / кофе / конфликт / недопонимание / извинение
- **Задачи по людям** — привязка задачи к контакту, вкладка "Задачи" в карточке
- **Договорённости** — сделки с процентом выполнения, суммой, статусом
- **Сделки как процесс** — rich-заметка, ссылки на договор/документы, этапы по датам и журнал обновлений
- **Сделки + Календарь** — дублирование дедлайна сделки в системный календарь, включая повторение по сроку действия
- **Конфликты** — отдельная вкладка для недопониманий и конфликтов
- Граф знакомств: кто кого познакомил

### Ритуалы и материалы
- **Ритуалы** — повторяющиеся дела (ежедневно / еженедельно / ежемесячно / пользовательский интервал)
- **Материалы** — ссылки, файлы, заметки с превью og:title, фильтрацией по типу и тегам

### Синхронизации
- **iCloud** — автоматическая синхронизация между Mac и iPhone (CloudKit)
- **Google Calendar** — добавление задач с датой прямо в Google Календарь (OAuth 2.0)
- **Airtable** — двусторонняя синхронизация, импорт таблиц как заметок
- **Airtable safe sync** — dry-run превью, стратегия конфликтов и управляемое применение изменений
- **Журнал синков Airtable** — история запусков dry-run/apply с итогами и ошибками
- **Экспорт журнала синков** — выгрузка истории в JSON/CSV для аудита
- **Conflict timestamp policy** — для сравнения версий используется `Last modified time` (fallback: `createdTime`)
- **Ограничение журнала** — история синков хранится в памяти текущей сессии (до перезапуска), затем доступна через экспорт
- **Импорт из Notion** — импорт страниц базы данных через Notion API

### UX
- **Тёмная тема** — принудительно тёмная по всему приложению
- **Без лагов** — LazyVStack, пагинация, оптимизированные FetchDescriptor
- **Быстрый поиск по заметкам** — debounce ввода и облегчённая фильтрация для больших списков (1000+)
- **Notes-like интерфейс заметок** — на macOS заметки открываются в формате список + детальная панель, ближе к Apple Notes
- **Форматирование заметок как в Notes** — формат через контекстное меню (правый клик) + hotkeys на macOS
- **Дедлайн заметки + Calendar** — заметка может иметь дедлайн и синхронизироваться с системным календарём (EventKit)

## Структура

```
Задачник/
├── App/
│   ├── ZadachnikApp.swift          # Точка входа, тёмная тема
│   └── PersistenceController.swift # SwiftData
├── Models/
│   ├── Project.swift + TaskItem.swift + QuickNote.swift + Person.swift + Interaction.swift
│   ├── Deal.swift                  # Договорённости/сделки
│   ├── MaterialLink.swift          # Ссылки и материалы
│   ├── RecurringPattern.swift      # Повторяемые действия
│   ├── CustomField.swift           # Кастомные поля
│   ├── VoiceMemo.swift             # Голосовые записи
│   └── Attachment.swift            # Прикреплённые файлы
├── Services/
│   ├── AIService.swift             # Claude + Perplexity + Keychain
│   ├── AirtableService.swift       # REST клиент Airtable
│   ├── GoogleCalendarService.swift # OAuth + Calendar API
│   └── VoiceRecorderService.swift  # AVAudioRecorder + SFSpeechRecognizer
├── Extensions/
│   ├── Color+Hex.swift
│   ├── Date+Extensions.swift
│   └── Platform+Adaptive.swift
└── Views/
    ├── ContentView.swift           # NavigationSplitView + AI sidebar
    ├── TodayView.swift             # Сегодня + автосортировка + теги
    ├── TaskDetailView.swift        # Форма задачи + кастомные поля + Google Cal
    ├── QuickNotesView.swift        # Заметки + теги + поиск + шаринг
    ├── AI/                         # AISidebarView, ChatBubbleView, AISettingsView
    ├── Deals/                      # DealsView, DealDetailView
    ├── Materials/                  # MaterialsView, AddMaterialView
    ├── Patterns/                   # PatternsView, AddPatternView
    ├── Voice/                      # VoiceMemosView, AttachmentsView
    ├── Search/                     # GlobalSearchView
    ├── People/                     # PeopleView, PersonDetailView (+ Задачи/Сделки/Конфликты)
    ├── Settings/                   # AppSettingsView, AISettingsView, ImportView, CustomFieldsSettingsView
    └── Components/
        ├── TagInputView.swift      # Chip-теги + TagFilterBar
        ├── SortToolbarItem.swift   # SortOption enum + SortToolbarButton
        ├── TaskCard.swift + PriorityBadge.swift + ProjectRow.swift
```

## Quick Start

### Требования

- macOS 14+ или iOS 17+
- Xcode 15+
- Apple ID (для запуска на iPhone нужен Developer Account)

### Запуск

1. Открыть `Задачник.xcodeproj` в Xcode
2. Выбрать схему `Zadachnik`
3. Выбрать устройство (Mac или iPhone)
4. ⌘R — запустить

### Работа с g3 (accumulative autonomous mode)

Используй `g3` прямо в корне проекта. Дальше агент перейдет в режим накопления требований: каждый новый `requirement>` добавляется в общий контекст и запускает новую итерацию автономной реализации.

```bash
# Просто запусти g3 в директории проекта
g3

# Пример сессии
requirement> create a simple web server in Python with Flask
# ... autonomous mode runs and implements it ...
requirement> add a /health endpoint that returns JSON
# ... autonomous mode runs again with both requirements ...
```

Рекомендация для этого проекта:
- Формулируй требования короткими инкрементами (1 изменение за шаг)
- После каждого шага проверяй diff и запуск приложения в Xcode
- Для новых итераций добавляй только дельту, не переписывай весь контекст

### iCloud синхронизация

Требует платного Apple Developer Account ($99/год):
1. Xcode → Signing & Capabilities → добавить iCloud capability
2. Включить CloudKit
3. Container ID: `iCloud.com.cek.zadachnik`

Без настройки iCloud приложение работает с локальным хранилищем.

### Пересоздание xcodeproj (при изменении project.yml)

```bash
/tmp/xcodegen/xcodegen/bin/xcodegen generate --spec project.yml
```

Или скачать xcodegen заново:
```bash
curl -L https://github.com/yonaskolb/XcodeGen/releases/download/2.44.1/xcodegen.zip -o /tmp/xg.zip
unzip /tmp/xg.zip -d /tmp/xg
chmod +x /tmp/xg/xcodegen/bin/xcodegen
/tmp/xg/xcodegen/bin/xcodegen generate
```

## Горячие клавиши

| Действие | Клавиши |
|---|---|
| Быстрая запись | ⌘⇧N |
| Новый элемент | ⌘N |

## Стек

| Компонент | Технология |
|---|---|
| UI | SwiftUI |
| Хранение | SwiftData |
| Синхронизация | CloudKit |
| Платформы | iOS 17, macOS 14 |

## Документация

- Базовое описание и запуск: `README.md`
- Параметры, ключи и схема: `PARAMS.md`
- Полная функциональная спецификация (для безопасных изменений функций/данных): `docs/FUNCTIONAL_SPEC.md`
