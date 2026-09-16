import SwiftUI
import MWDATCore
import MWDATCamera
import MWDATDisplay

@main
struct JARVISReaderApp: App {
    private let configurationStatus: String

    init() {
        do {
            try Wearables.configure()
            configurationStatus = "Wearables.configure(): OK"
        } catch {
            configurationStatus = "Wearables.configure() FAILED: \(error)"
            print(configurationStatus)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(configurationStatus: configurationStatus)
                .onOpenURL { url in
                    Task { @MainActor in
                        if JARVISShortcutClient.shared.canHandle(url) {
                            JARVISShortcutClient.shared.handleCallback(url)
                        } else {
                            _ = try? await Wearables.shared.handleUrl(url)
                        }
                    }
                }
        }
    }
}
