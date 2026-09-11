import SwiftUI

struct ContentView: View {
    let configurationStatus: String
    @StateObject private var controller: JARVISController

    init(configurationStatus: String) {
        self.configurationStatus = configurationStatus
        _controller = StateObject(wrappedValue: JARVISController())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 54))

                    Text("JARVIS Reader")
                        .font(.largeTitle.bold())

                    statusCard
                    actionCard

                    if !controller.lastAnswer.isEmpty {
                        answerCard
                    }

                    diagnostics
                }
                .padding(24)
            }
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var statusCard: some View {
        VStack(spacing: 8) {
            Text(controller.isReady ? "READY" : controller.status)
                .font(controller.isReady ? .title2.bold() : .headline)
                .multilineTextAlignment(.center)

            HStack(spacing: 14) {
                statusPill("Meta", controller.registrationLabel)
                statusPill("Camera", controller.cameraPermissionLabel)
                statusPill("Devices", "\(controller.deviceCount)")
            }

            if controller.isReady {
                Text("Tap the JARVIS card on your glasses to capture → Gemini → answer on the display.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var actionCard: some View {
        VStack(spacing: 12) {
            if !controller.isRegistered {
                Button(controller.isRegistering ? "Opening Meta AI…" : "Register with Meta AI") {
                    controller.register()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isRegistering)
            } else if !controller.cameraPermissionGranted {
                Button(controller.isRequestingPermission ? "Opening Meta AI…" : "Grant Camera Access") {
                    controller.requestCameraPermission()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isRequestingPermission)
            } else if controller.isReady {
                Button(controller.isProcessing ? "Thinking…" : "Capture & Ask") {
                    controller.captureAndAsk()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isProcessing)

                Button("Disconnect") {
                    controller.disconnect()
                }
                .buttonStyle(.bordered)
            } else {
                Button(controller.isConnecting ? "Connecting…" : "Connect Glasses") {
                    controller.connect()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isConnecting)

                if controller.deviceCount == 0 {
                    Text("Camera access is granted. Keep the glasses on and connected in Meta AI; JARVIS will connect automatically when DAT exposes them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if controller.requiresDATAppUpdate {
                Button("Update DAT App on Glasses") {
                    controller.openDATGlassesAppUpdate()
                }
                .buttonStyle(.bordered)
            }

            Button("Refresh Status") {
                controller.refresh()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last answer")
                .font(.headline)
            Text(controller.lastAnswer)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var diagnostics: some View {
        DisclosureGroup("Diagnostics / Backend") {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    Text("SDK: \(controller.registrationLabel)")
                    Text("Session: \(controller.sessionLabel)")
                    Text("Stream: \(controller.streamLabel)")
                    Text("Display: \(controller.displayLabel)")
                    Text("Active device: \(controller.hasActiveDevice ? "yes" : "no")")
                    Text(configurationStatus)
                    Text("Signing Team ID: \(signingTeamID())")
                    Text("Configured TeamID: \(configuredMWDATValue("TeamID"))")
                    Text("Configured MetaAppID: \(configuredMWDATValue("MetaAppID"))")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

                Divider()

                Text("Backend")
                    .font(.subheadline.bold())
                Text(JARVISBackendClient.defaultEndpoint.absoluteString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                SecureField("Backend token (optional)", text: $controller.backendToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                Text("The token can stay blank unless JARVIS_NATIVE_TOKEN is enabled on the Supabase function.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func statusPill(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary, in: Capsule())
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
}
