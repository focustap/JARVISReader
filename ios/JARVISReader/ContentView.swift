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
            ScrollView {
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

                    VStack(spacing: 4) {
                        Text("Signing Team ID: \(signingTeamID())")
                        Text("Configured TeamID: \(configuredMWDATValue("TeamID"))")
                        Text("Configured MetaAppID: \(configuredMWDATValue("MetaAppID"))")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

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

                    Text("If registration stays unavailable, send the SDK state plus the Signing Team ID and Configured TeamID shown above.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
            }
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

    private func configuredMWDATValue(_ key: String) -> String {
        guard let config = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any],
              let value = config[key] as? String,
              !value.isEmpty else {
            return "<empty>"
        }
        return value
    }

    private func signingTeamID() -> String {
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: profileURL),
              let text = String(data: data, encoding: .isoLatin1) else {
            return "<not found>"
        }

        let patterns = [
            #"<key>com\.apple\.developer\.team-identifier</key>\s*<string>([^<]+)</string>"#,
            #"<key>TeamIdentifier</key>\s*<array>\s*<string>([^<]+)</string>"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..<text.endIndex, in: text)
                  ),
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            return String(text[range])
        }

        return "<not found>"
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
