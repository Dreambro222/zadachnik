import SwiftUI

// MARK: - Platform-adaptive colors

extension Color {
    /// Grouped background (like UITableView .insetGrouped)
    static var groupedBackground: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    /// Secondary grouped background (card surface)
    static var secondaryGroupedBackground: Color {
        #if os(iOS)
        Color(.secondarySystemGroupedBackground)
        #else
        Color(NSColor.controlBackgroundColor)
        #endif
    }
}

// MARK: - Platform-adaptive modifiers

extension View {
    /// Inline navigation title — iOS only, no-op on macOS
    @ViewBuilder
    func navigationInline() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Large navigation title — iOS only, no-op on macOS
    @ViewBuilder
    func navigationLarge() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.large)
        #else
        self
        #endif
    }

    /// `.listStyle(.insetGrouped)` — iOS only, falls back to `.inset` on macOS
    @ViewBuilder
    func adaptiveListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }

    /// Email keyboard type + disable autocapitalization — iOS only
    @ViewBuilder
    func emailInputStyle() -> some View {
        #if os(iOS)
        self
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// Phone pad keyboard — iOS only
    @ViewBuilder
    func phoneInputStyle() -> some View {
        #if os(iOS)
        self.keyboardType(.phonePad)
        #else
        self
        #endif
    }
}
