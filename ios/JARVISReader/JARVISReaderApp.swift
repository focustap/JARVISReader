import SwiftUI
import MWDATCore
import MWDATCamera
import MWDATDisplay

@main
struct JARVISReaderApp: App {
    init() {
        do {
            try Wearables.configure()
        } catch {
            print("Wearables configuration failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    Task {
                        _ = try? await Wearables.shared.handleUrl(url)
                    }
                }
        }
    }
}
