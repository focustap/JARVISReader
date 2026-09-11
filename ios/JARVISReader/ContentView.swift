import SwiftUI
import MWDATCore

struct ContentView: View {
    @State private var status = "Ready to register with Meta AI"
    @State private var isRegistering = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 54))

                Text("JARVIS Reader")
                    .font(.largeTitle.bold())

                Text(status)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button(isRegistering ? "Opening Meta AI…" : "Register Glasses") {
                    register()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRegistering)

                Text("Native camera + Display integration is being built on this branch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
        }
    }

    private func register() {
        isRegistering = true
        status = "Opening Meta AI for permission…"

        Task {
            do {
                try await Wearables.shared.startRegistration()
                await MainActor.run {
                    status = "Registration request started. Finish it in Meta AI."
                    isRegistering = false
                }
            } catch {
                await MainActor.run {
                    status = "Registration failed: \(error.localizedDescription)"
                    isRegistering = false
                }
            }
        }
    }
}
