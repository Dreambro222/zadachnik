#if os(macOS)
import AppKit
import SwiftUI
import SwiftData

// MARK: - Menu Bar Manager
// NSStatusItem в строке меню для быстрого старта/стопа записи звонков.
// Показывает индикатор (красная точка) во время записи.

@MainActor
final class MenuBarManager: ObservableObject {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private var modelContainer: ModelContainer?

    @Published var isRecording = false

    private init() {}

    func setup(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateButton()
    }

    // MARK: - Button update

    func updateButton() {
        guard let button = statusItem?.button else { return }

        if isRecording {
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Запись")
            button.image?.isTemplate = false
            // Красный цвет через attributedTitle
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            button.toolTip = "Запись звонка... (нажмите для остановки)"
        } else {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Запись звонка")
            button.image?.isTemplate = true
            button.toolTip = "Задачник: записать звонок"
        }

        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
        } else {
            if isRecording {
                stopRecording()
            } else {
                showQuickRecordMenu()
            }
        }
    }

    // MARK: - Menus

    private func showQuickRecordMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Записать звонок", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(NSMenuItem.separator())

        for source in CallSource.allCases {
            let item = NSMenuItem(
                title: "\(source.label) (BlackHole)",
                action: #selector(startRecordingWithSource(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = sourceTag(source)
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Открыть Задачник", action: #selector(openApp), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func showMenu() {
        let menu = NSMenu()

        if isRecording {
            let stopItem = NSMenuItem(title: "Остановить запись", action: #selector(stopRecordingAction), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            let noRecItem = NSMenuItem(title: "Нет активной записи", action: nil, keyEquivalent: "")
            noRecItem.isEnabled = false
            menu.addItem(noRecItem)
        }

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Открыть Задачник", action: #selector(openApp), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - Actions

    @objc private func startRecordingWithSource(_ sender: NSMenuItem) {
        let source = callSource(from: sender.tag)
        Task { @MainActor in
            await beginRecording(source: source)
        }
    }

    @objc private func stopRecordingAction() {
        stopRecording()
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Recording logic

    func beginRecording(source: CallSource) async {
        let granted = await CallRecorderService.shared.requestMicrophonePermission()
        guard granted else {
            showNotification(title: "Нет доступа к микрофону", body: "Разрешите доступ в Системных настройках")
            return
        }

        do {
            _ = try CallRecorderService.shared.startRecording(useBlackHole: CallRecorderService.shared.blackHoleAvailable)
            isRecording = true
            updateButton()

            // Создаём VoiceMemo в SwiftData
            if let container = modelContainer {
                let ctx = ModelContext(container)
                let memo = VoiceMemo(
                    fileName: "call_\(UUID().uuidString).m4a",
                    duration: 0,
                    isCallRecording: true,
                    callSource: source,
                    callerName: "",
                    linkedPersonId: nil
                )
                ctx.insert(memo)
                try? ctx.save()
            }

            showNotification(
                title: "Запись начата",
                body: "\(source.label) · \(CallRecorderService.shared.blackHoleAvailable ? "BlackHole (оба голоса)" : "Микрофон")"
            )
        } catch {
            NSLog("[MenuBar] Recording error: \(error)")
            showNotification(title: "Ошибка записи", body: error.localizedDescription)
        }
    }

    func stopRecording() {
        guard let result = CallRecorderService.shared.stopRecording() else { return }
        isRecording = false
        updateButton()

        showNotification(title: "Запись остановлена", body: "Длительность: \(formatDuration(result.duration)). Транскрибирую...")

        Task {
            let transcription = await WhisperService.shared.transcribe(url: result.url)
            NSLog("[MenuBar] Transcription done: \(transcription.text.prefix(100))")
            showNotification(
                title: "Транскрипция готова",
                body: transcription.text.prefix(100).isEmpty ? "Текст не распознан" : String(transcription.text.prefix(100)) + "..."
            )
        }
    }

    // MARK: - Notifications

    private func showNotification(title: String, body: String) {
        let content = NSUserNotification()
        content.title = title
        content.informativeText = body
        NSUserNotificationCenter.default.deliver(content)
    }

    // MARK: - Helpers

    private func sourceTag(_ source: CallSource) -> Int {
        switch source {
        case .microphone: return 0
        case .telegram:   return 1
        case .zoom:       return 2
        case .phone:      return 3
        case .other:      return 4
        }
    }

    private func callSource(from tag: Int) -> CallSource {
        switch tag {
        case 0: return .microphone
        case 1: return .telegram
        case 2: return .zoom
        case 3: return .phone
        default: return .other
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
#endif
