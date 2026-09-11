import SwiftUI
import MWDATCore

struct ContentView: View {
    @State private var status = "Ready to register with Meta AI"
    @State private var isRegistering = false
    @State private var registrationState = String(describing: Wearables.shared.registrationState)
    @State private var deviceCount = Wearables.shared.devices.count

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 54))

                Text("JARVIS Reader")
                    .font(.largeTitle.bold())

                VStack(spacing: 6) {
                    Text("SDK state: \(registrationState)")
                        .font(.headline)
                    Text("Detected devices: \(deviceCount)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(status)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button(isRegistering ? "Opening Meta AI…" : "Register / Retry") {
                    register()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRegistering)

                Button("Refresh SDK Status") {
                    refreshStatus()
                }
                .buttonStyle(.bordered)

                Text("If Meta AI opens without an approval sheet, return to JARVIS and tell me the SDK state shown above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .task {
                refreshStatus()

                for await state in Wearables.shared.registrationStateStream() {
                    await MainActor.run {
                        registrationState = String(describing: state)
                        deviceCount = Wearables.shared.devices.count

                        switch state {
                        case .registered:
                            status = "Registered with Meta AI."
                            isRegistering = false
                        case .registering:
                            status = "Meta registration is in progress…"
                        case .available:
                            status = "Registration is available. Tap Register / Retry."
                            isRegistering = false
                        case .unavailable:
                            status = "Registration is unavailable. Check Meta AI Developer Mode, glasses connection, and internet."
                            isRegistering = false
                        }
                    }
                }
            }
        }
    }

    private func refreshStatus() {
        registrationState = String(describing: Wearables.shared.registrationState)
        deviceCount = Wearables.shared.devices.count
    }

    private func register() {
        isRegistering = true
        status = "Opening Meta AI for permission…"
        refreshStatus()

        Task {
            do {
                try await Wearables.shared.startRegistration()
                await MainActor.run {
                    refreshStatus()
                    status = "Registration request sent. If Meta AI shows no approval sheet, return here and read the SDK state."
                    isRegistering = false
                }
            } catch let error as RegistrationError {
                await MainActor.run {
                    refreshStatus()
                    status = "Registration error: \(error.description)"
                    isRegistering = false
                }
            } catch {
                await MainActor.run {
                    refreshStatus()
                    status = "Registration failed: \(error.localizedDescription)"
                    isRegistering = false
                }
            }
        }
    }
}
