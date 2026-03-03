import EventKit
import Foundation
import SwiftUI

enum CalendarRecurrenceFrequency {
    case daily
    case weekly
    case monthly
}

struct CalendarRecurrence {
    var frequency: CalendarRecurrenceFrequency
    var interval: Int
}

// MARK: - EventKit-based Calendar Service (no OAuth, no API keys)
// Works like Zoom, Fantastical, Things — uses system Calendar.app
// which auto-syncs with Google Calendar if added in System Settings

@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    @Published var isAuthorized = false
    @Published var availableCalendars: [EKCalendar] = []
    @Published var selectedCalendarId: String = ""

    private let store = EKEventStore()
    private let calendarIdKey = "zadachnik.eventkit.calendarId"

    private init() {
        selectedCalendarId = UserDefaults.standard.string(forKey: calendarIdKey) ?? ""
        checkAuthorizationStatus()
        // Listen for external calendar changes (new accounts added in System Settings)
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkAuthorizationStatus()
            }
        }
    }

    // MARK: - Authorization

    func checkAuthorizationStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:
            isAuthorized = true
            loadCalendars()
        case .notDetermined:
            isAuthorized = false
        default:
            isAuthorized = false
        }
    }

    func requestAccess() async -> Bool {
        do {
            let granted: Bool
            if #available(macOS 14.0, iOS 17.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            isAuthorized = granted
            if granted { loadCalendars() }
            return granted
        } catch {
            isAuthorized = false
            return false
        }
    }

    // MARK: - Calendars

    func refresh() {
        // Force EKEventStore to reload — picks up newly added accounts
        store.reset()
        checkAuthorizationStatus()
    }

    func loadCalendars() {
        let cals = store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .sorted { $0.title < $1.title }
        availableCalendars = cals

        // Keep saved selection if still valid, otherwise pick default
        if !selectedCalendarId.isEmpty && cals.contains(where: { $0.calendarIdentifier == selectedCalendarId }) {
            // keep saved selection
        } else {
            selectedCalendarId = store.defaultCalendarForNewEvents?.calendarIdentifier ?? cals.first?.calendarIdentifier ?? ""
            if !selectedCalendarId.isEmpty {
                UserDefaults.standard.set(selectedCalendarId, forKey: calendarIdKey)
            }
        }
    }

    func selectCalendar(_ calendar: EKCalendar) {
        selectedCalendarId = calendar.calendarIdentifier
        UserDefaults.standard.set(selectedCalendarId, forKey: calendarIdKey)
    }

    var selectedCalendar: EKCalendar? {
        availableCalendars.first { $0.calendarIdentifier == selectedCalendarId }
            ?? store.defaultCalendarForNewEvents
    }

    // MARK: - Create / Update event

    @discardableResult
    func createOrUpdateEvent(
        title: String,
        startDate: Date,
        endDate: Date? = nil,
        notes: String = "",
        existingEventId: String = "",
        isAllDay: Bool = false,
        recurrence: CalendarRecurrence? = nil
    ) async throws -> String {
        if !isAuthorized {
            let granted = await requestAccess()
            guard granted else { throw CalendarError.notAuthorized }
        }

        let event: EKEvent

        // Update existing event if we have its ID
        if !existingEventId.isEmpty,
           let existing = store.event(withIdentifier: existingEventId) {
            event = existing
        } else {
            event = EKEvent(eventStore: store)
        }

        let end = endDate ?? Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate

        event.title     = title
        event.startDate = startDate
        event.endDate   = isAllDay ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: startDate))! : end
        event.isAllDay  = isAllDay
        event.notes     = notes
        event.calendar  = selectedCalendar
        if let recurrence {
            let frequency: EKRecurrenceFrequency
            switch recurrence.frequency {
            case .daily: frequency = .daily
            case .weekly: frequency = .weekly
            case .monthly: frequency = .monthly
            }
            let safeInterval = max(1, recurrence.interval)
            event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: frequency, interval: safeInterval, end: nil)]
        } else {
            event.recurrenceRules = nil
        }

        try store.save(event, span: .thisEvent)
        return event.eventIdentifier ?? ""
    }

    // MARK: - Delete event

    func deleteEvent(eventId: String) {
        guard !eventId.isEmpty,
              let event = store.event(withIdentifier: eventId) else { return }
        try? store.remove(event, span: .thisEvent)
    }

    // MARK: - Open in Calendar.app

    func openInCalendar(date: Date) {
        let interval = date.timeIntervalSinceReferenceDate
        if let url = URL(string: "ical://\(interval)") {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        }
    }
}

enum CalendarError: LocalizedError {
    case notAuthorized
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:      return "Нет доступа к Календарю. Разрешите в Системных настройках."
        case .saveFailed(let m):  return "Ошибка сохранения: \(m)"
        }
    }
}
