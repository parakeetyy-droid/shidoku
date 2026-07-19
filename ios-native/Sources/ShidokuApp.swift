import SwiftUI

@main
struct ShidokuApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                // Real VI hides the status bar — there is no clock or battery
                // over the viewfinder in any frame of the owner's recording,
                // and the demo matches that. Without this the app shows one.
                .statusBarHidden(true)
        }
    }
}
