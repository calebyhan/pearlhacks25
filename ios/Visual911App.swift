import SwiftUI

@main
struct Visual911App: App {
    @StateObject private var callManager = CallManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(callManager)
        }
    }
}
