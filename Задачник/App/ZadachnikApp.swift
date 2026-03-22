import SwiftUI

@main
struct ZadachnikApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if os(macOS)
                .frame(minWidth: 400, minHeight: 300)
                #endif
        }
    }
}
