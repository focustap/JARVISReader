import SwiftUI
import MWDATCore

struct ContentView: View {
    let configurationStatus: String

    @State private var status = "Ready to register with Meta AI"
    @State private var isRegistering = false
    @State private var registrationState = "Checking…"
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
                    Text(configurationStatus)
                        .font(.caption)
                        .foregroundStyle(configurationStatus.contains("FAILED") ? .red : .secondary)
                        .multilineTextAlignment(.center)
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

                Text("If registration is unavailable, make sure Developer Mode is enabled for these glasses in Meta AI. If configure() shows FAILED, send me the full error shown above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .task {
                refreshStatus()

                for await state in Wearables.shared.registrationStateStream() {
                    await MainActor.run {
                        registrationState = label(for: state)
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
                            status = "Registration is unavailable. Meta is not currently exposing a registerable wearable to JARVIS."
                            isRegistering = false
                        }
                    }
                }
            }
        }
    }

    private func label(for state: RegistrationState) -> String {
        switch state {
        case .registered: return "registered"
        case .registering: return "registering"
        case .available: return "available"
        case .unavailable: return "unavailable"
        }
    }

    private func refreshStatus() {
        registrationState = label(for: Wearables.shared.registrationState)
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
                    status = "Registration request sent. Return here after Meta AI and check the state above."
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
