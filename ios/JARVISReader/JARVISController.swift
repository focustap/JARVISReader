import Combine
import Foundation
import MWDATCamera
import MWDATCore
import MWDATDisplay
import UIKit

struct JARVISDeviceInfo: Identifiable {
    let identifier: DeviceIdentifier
    let name: String
    let type: String
    let linkState: LinkState
    let compatibility: Compatibility
    let supportsDisplay: Bool

    var id: DeviceIdentifier { identifier }

    var statusText: String {
        if compatibility == .deviceUpdateRequired {
            return "Update required"
        }

        switch linkState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        @unknown default: return "Unknown"
        }
    }

    var compatibilityText: String {
        compatibility == .deviceUpdateRequired ? "update required" : "compatible"
    }
}

@MainActor
final class JARVISController: ObservableObject {
    @Published private(set) var registrationState = Wearables.shared.registrationState
    @Published private(set) var deviceCount = Wearables.shared.devices.count
    @Published private(set) var deviceInfos: [JARVISDeviceInfo] = []
    @Published private(set) var selectedDeviceIdentifier: DeviceIdentifier?
    @Published private(set) var hasActiveDevice = false
    @Published private(set) var cameraPermissionGranted = false
    @Published private(set) var cameraPermissionChecked = false
    @Published private(set) var sessionState: DeviceSessionState = .idle
    @Published private(set) var streamState: StreamState = .stopped
    @Published private(set) var displayState: DisplayState = .stopped
    @Published private(set) var status = "Starting JARVIS…"
    @Published private(set) var lastAnswer = ""
    @Published private(set) var lastPhoto: UIImage?
    @Published private(set) var isProcessing = false
    @Published private(set) var isRegistering = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var isConnecting = false
    @Published private(set) var requiresDATAppUpdate = false
    @Published private(set) var requiresFirmwareUpdate = false
    @Published var backendToken: String {
        didSet {
            UserDefaults.standard.set(backendToken, forKey: Self.backendTokenKey)
        }
    }

    private static let backendTokenKey = "jarvisNativeBackendToken"

    private let wearables: WearablesInterface
    private let backend = JARVISBackendClient()

    private var deviceSession: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private var display: Display?

    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?

    private var deviceLinkTokens: [DeviceIdentifier: AnyListenerToken] = [:]
    private var deviceCompatibilityTokens: [DeviceIdentifier: AnyListenerToken] = [:]
    private var sessionStateToken: AnyListenerToken?
    private var sessionErrorToken: AnyListenerToken?
    private var streamStateToken: AnyListenerToken?
    private var streamErrorToken: AnyListenerToken?
    private var photoToken: AnyListenerToken?
    private var displayStateToken: AnyListenerToken?

    private var autoConnectWhenDeviceAppears = false
    private var sentReadyCard = false
    private var lastSessionError: String?

    init(wearables: WearablesInterface = Wearables.shared) {
        self.wearables = wearables
        self.backendToken = UserDefaults.standard.string(forKey: Self.backendTokenKey) ?? ""

        startObservers()
        refresh()
    }

    var isRegistered: Bool {
        registrationState == .registered
    }

    var isReady: Bool {
        sessionState == .started && streamState == .streaming && displayState == .started
    }

    var selectedDeviceName: String {
        guard let selectedDeviceIdentifier,
              let info = deviceInfos.first(where: { $0.identifier == selectedDeviceIdentifier }) else {
            return "none"
        }
        return info.name
    }

    var registrationLabel: String {
        switch registrationState {
        case .registered: return "registered"
        case .registering: return "registering"
        case .available: return "available"
        case .unavailable: return "unavailable"
        }
    }

    var cameraPermissionLabel: String {
        guard cameraPermissionChecked else { return "unknown" }
        return cameraPermissionGranted ? "granted" : "not granted"
    }

    var sessionLabel: String {
        switch sessionState {
        case .idle: return "idle"
        case .starting: return "starting"
        case .started: return "started"
        case .paused: return "paused"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        }
    }

    var streamLabel: String {
        switch streamState {
        case .streaming: return "streaming"
        case .starting: return "starting"
        case .waitingForDevice: return "waiting for device"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .paused: return "paused"
        }
    }

    var displayLabel: String {
        switch displayState {
        case .starting: return "starting"
        case .started: return "started"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        }
    }

    func isSelectedDevice(_ identifier: DeviceIdentifier) -> Bool {
        selectedDeviceIdentifier == identifier
    }

    func refresh() {
        registrationState = wearables.registrationState
        updateDevices(Array(wearables.devices))

        if registrationState == .registered {
            Task { await refreshCameraPermission() }
        } else {
            cameraPermissionChecked = false
            cameraPermissionGranted = false
        }
    }

    func register() {
        guard !isRegistering else { return }
        isRegistering = true
        status = "Opening Meta AI for registration…"

        Task {
            defer { isRegistering = false }
            do {
                try await wearables.startRegistration()
                registrationState = wearables.registrationState
                status = registrationState == .registered
                    ? "Registered. Grant camera access next."
                    : "Registration request sent. Finish approval in Meta AI."
            } catch let error as RegistrationError {
                status = "Registration error: \(error.description)"
            } catch {
                status = "Registration failed: \(error.localizedDescription)"
            }
        }
    }

    func requestCameraPermission() {
        guard isRegistered, !isRequestingPermission else { return }
        isRequestingPermission = true
        status = "Opening Meta AI for camera permission…"

        Task {
            defer { isRequestingPermission = false }
            do {
                let result = try await wearables.requestPermission(.camera)
                cameraPermissionChecked = true
                cameraPermissionGranted = result == .granted

                if cameraPermissionGranted {
                    status = "Camera access granted. Looking for your glasses…"
                    autoConnectWhenDeviceAppears = true
                    updateDevices(Array(wearables.devices))
                    connectIfPossible()
                } else {
                    status = "Camera permission was not granted."
                }
            } catch {
                cameraPermissionChecked = true
                cameraPermissionGranted = false
                status = "Camera permission error: \(error.localizedDescription)"
            }
        }
    }

    func selectDevice(_ identifier: DeviceIdentifier) {
        guard let info = deviceInfos.first(where: { $0.identifier == identifier }) else {
            status = "That device is no longer available."
            return
        }
        guard info.supportsDisplay else {
            status = "\(info.name) does not expose a glasses display to DAT."
            return
        }

        if deviceSession != nil {
            disconnect()
        }

        selectedDeviceIdentifier = identifier
        updateActiveDeviceFlag()
        status = hasActiveDevice
            ? "Selected \(info.name). Ready to connect."
            : "Selected \(info.name). Waiting for it to connect…"
    }

    func connect() {
        guard isRegistered else {
            status = "Register with Meta AI first."
            return
        }
        guard cameraPermissionGranted else {
            status = "Grant camera access first."
            return
        }

        autoConnectWhenDeviceAppears = true
        updateDevices(Array(wearables.devices))
        connectIfPossible()
    }

    func captureAndAsk() {
        guard isReady else {
            status = "Glasses are not ready yet."
            return
        }
        guard !isProcessing else { return }

        isProcessing = true
        status = "Capturing from the glasses…"

        Task { await sendWorkingToDisplay("Capturing…") }

        let didStart = camera?.stream.capturePhoto(format: .jpeg) ?? false
        if !didStart {
            finishWithError("The glasses could not capture a photo. Try again.")
        }
    }

    func disconnect() {
        sentReadyCard = false
        autoConnectWhenDeviceAppears = false
        isProcessing = false

        display?.stop()
        camera?.stop()
        deviceSession?.stop()

        clearCapabilityReferences()
        clearSessionReferences()
        sessionState = .idle
        streamState = .stopped
        displayState = .stopped
        status = "Disconnected."
    }

    func openDATGlassesAppUpdate() {
        Task {
            do {
                try await wearables.openDATGlassesAppUpdate()
            } catch {
                status = "Could not open DAT update: \(error.localizedDescription)"
            }
        }
    }

    func openFirmwareUpdate() {
        Task {
            do {
                try await wearables.openFirmwareUpdate()
            } catch {
                status = "Could not open firmware update: \(error.localizedDescription)"
            }
        }
    }

    private func startObservers() {
        registrationTask = Task { [weak self] in
            guard let wearables = self?.wearables else { return }
            for await state in wearables.registrationStateStream() {
                guard let self, !Task.isCancelled else { return }
                self.registrationState = state

                switch state {
                case .registered:
                    self.status = "Registered with Meta AI."
                    self.updateDevices(Array(wearables.devices))
                    await self.refreshCameraPermission()
                case .registering:
                    self.status = "Registration is in progress…"
                case .available:
                    self.status = "Ready to register with Meta AI."
                    self.disconnectForRegistrationReset()
                case .unavailable:
                    self.status = "Meta registration is currently unavailable."
                    self.disconnectForRegistrationReset()
                }
            }
        }

        devicesTask = Task { [weak self] in
            guard let wearables = self?.wearables else { return }
            for await deviceIDs in wearables.devicesStream() {
                guard let self, !Task.isCancelled else { return }
                self.updateDevices(deviceIDs)
            }
        }
    }

    private func updateDevices(_ deviceIDs: [DeviceIdentifier]) {
        deviceCount = deviceIDs.count
        let currentIDs = Set(deviceIDs)

        let removedLinkIDs = deviceLinkTokens.keys.filter { !currentIDs.contains($0) }
        for id in removedLinkIDs {
            if let token = deviceLinkTokens.removeValue(forKey: id) {
                Task { await token.cancel() }
            }
        }

        let removedCompatibilityIDs = deviceCompatibilityTokens.keys.filter { !currentIDs.contains($0) }
        for id in removedCompatibilityIDs {
            if let token = deviceCompatibilityTokens.removeValue(forKey: id) {
                Task { await token.cancel() }
            }
        }

        var infos: [JARVISDeviceInfo] = []
        for identifier in deviceIDs {
            guard let device = wearables.deviceForIdentifier(identifier) else { continue }
            infos.append(deviceInfo(for: device))
            ensureDeviceListeners(for: device)
        }
        deviceInfos = infos
        requiresFirmwareUpdate = infos.contains { $0.compatibility == .deviceUpdateRequired }

        let connectedDisplay = infos.first { $0.supportsDisplay && $0.linkState == .connected }
        let anyDisplay = infos.first { $0.supportsDisplay }

        if let selectedDeviceIdentifier,
           let selectedInfo = infos.first(where: { $0.identifier == selectedDeviceIdentifier && $0.supportsDisplay }) {
            if selectedInfo.linkState != .connected, let connectedDisplay {
                self.selectedDeviceIdentifier = connectedDisplay.identifier
            }
        } else {
            selectedDeviceIdentifier = connectedDisplay?.identifier ?? anyDisplay?.identifier
        }

        updateActiveDeviceFlag()

        if autoConnectWhenDeviceAppears {
            connectIfPossible()
        }
    }

    private func deviceInfo(for device: Device) -> JARVISDeviceInfo {
        JARVISDeviceInfo(
            identifier: device.identifier,
            name: device.nameOrId(),
            type: device.deviceType().rawValue,
            linkState: device.linkState,
            compatibility: device.compatibility(),
            supportsDisplay: device.supportsDisplay()
        )
    }

    private func ensureDeviceListeners(for device: Device) {
        let identifier = device.identifier

        if deviceLinkTokens[identifier] == nil {
            deviceLinkTokens[identifier] = device.addLinkStateListener { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.updateDevices(Array(self.wearables.devices))
                }
            }
        }

        if deviceCompatibilityTokens[identifier] == nil {
            deviceCompatibilityTokens[identifier] = device.addCompatibilityListener { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.updateDevices(Array(self.wearables.devices))
                }
            }
        }
    }

    private func updateActiveDeviceFlag() {
        guard let selectedDeviceIdentifier,
              let info = deviceInfos.first(where: { $0.identifier == selectedDeviceIdentifier }) else {
            hasActiveDevice = false
            return
        }

        hasActiveDevice = info.supportsDisplay && info.linkState == .connected
    }

    private func refreshCameraPermission() async {
        guard isRegistered else {
            cameraPermissionChecked = false
            cameraPermissionGranted = false
            return
        }

        do {
            let result = try await wearables.checkPermissionStatus(.camera)
            cameraPermissionChecked = true
            cameraPermissionGranted = result == .granted

            if cameraPermissionGranted && deviceSession == nil {
                status = hasActiveDevice
                    ? "Camera access granted. Ready to connect."
                    : "Camera access granted. Waiting for display-capable glasses…"
            }
        } catch {
            cameraPermissionChecked = true
            cameraPermissionGranted = false
            status = "Could not check camera permission: \(error.localizedDescription)"
        }
    }

    private func connectIfPossible() {
        guard autoConnectWhenDeviceAppears,
              isRegistered,
              cameraPermissionGranted,
              deviceSession == nil,
              !isConnecting else {
            return
        }

        guard let selectedDeviceIdentifier else {
            status = deviceCount == 0
                ? "Waiting for your Meta glasses…"
                : "No display-capable glasses found. Check the device list below."
            return
        }

        guard hasActiveDevice else {
            let name = deviceInfos.first(where: { $0.identifier == selectedDeviceIdentifier })?.name ?? "selected glasses"
            status = "Waiting for \(name) to connect…"
            return
        }

        guard let selectedInfo = deviceInfos.first(where: { $0.identifier == selectedDeviceIdentifier }) else {
            status = "Selected glasses disappeared. Refreshing devices…"
            updateDevices(Array(wearables.devices))
            return
        }

        if selectedInfo.compatibility == .deviceUpdateRequired {
            requiresFirmwareUpdate = true
            status = "\(selectedInfo.name) needs a firmware update before JARVIS can connect."
            return
        }

        isConnecting = true
        lastSessionError = nil
        status = "Starting session with \(selectedInfo.name)…"
        requiresDATAppUpdate = false

        do {
            let selector = SpecificDeviceSelector(device: selectedDeviceIdentifier)
            let session = try wearables.createSession(deviceSelector: selector)
            deviceSession = session
            observeSession(session)
            sessionState = .starting
            try session.start()
        } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
            isConnecting = false
            requiresDATAppUpdate = true
            lastSessionError = DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription
            status = "The DAT app on the glasses needs an update."
            clearSessionReferences()
        } catch {
            isConnecting = false
            lastSessionError = error.localizedDescription
            status = "Could not start glasses session: \(error.localizedDescription)"
            clearSessionReferences()
        }
    }

    private func observeSession(_ session: DeviceSession) {
        sessionStateToken = session.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                self?.handleSessionState(state, session: session)
            }
        }

        sessionErrorToken = session.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                self?.handleSessionError(error)
            }
        }
    }

    private func handleSessionState(_ state: DeviceSessionState, session: DeviceSession) {
        sessionState = state

        switch state {
        case .started:
            isConnecting = false
            lastSessionError = nil
            status = "Session connected. Starting camera and display…"
            setupCapabilities(on: session)
        case .stopping:
            if lastSessionError == nil {
                status = "Stopping glasses session…"
            }
        case .stopped:
            isConnecting = false
            sentReadyCard = false
            clearCapabilityReferences()
            clearSessionReferences()
            streamState = .stopped
            displayState = .stopped
            if let lastSessionError {
                status = "Glasses session error: \(lastSessionError)"
            } else {
                status = "Glasses session stopped."
            }
        case .starting, .idle, .paused:
            break
        }
    }

    private func handleSessionError(_ error: DeviceSessionError) {
        isConnecting = false
        requiresDATAppUpdate = error == .datAppOnTheGlassesUpdateRequired
        lastSessionError = error.localizedDescription
        status = "Glasses session error: \(error.localizedDescription)"
        if isProcessing {
            isProcessing = false
        }
    }

    private func setupCapabilities(on session: DeviceSession) {
        if display == nil {
            do {
                let newDisplay = try session.addDisplay()
                display = newDisplay
                displayStateToken = newDisplay.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        self?.handleDisplayState(state)
                    }
                }
                displayState = .starting
                newDisplay.start()
            } catch {
                status = "Could not start the glasses display: \(error.localizedDescription)"
            }
        }

        if camera == nil {
            let config = StreamConfiguration(
                videoCodec: .raw,
                resolution: .medium,
                frameRate: 15
            )

            do {
                guard let newCamera = try session.addCamera(config: config) else {
                    status = "Could not create the glasses camera."
                    return
                }

                camera = newCamera
                let stream = newCamera.stream

                streamStateToken = stream.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        self?.handleStreamState(state)
                    }
                }

                streamErrorToken = stream.errorPublisher.listen { [weak self] error in
                    Task { @MainActor in
                        self?.handleStreamError(error)
                    }
                }

                photoToken = stream.photoDataPublisher.listen { [weak self] photoData in
                    let bytes = Data(photoData.data)
                    Task { @MainActor in
                        self?.handlePhoto(bytes)
                    }
                }

                streamState = .starting
                stream.start()
            } catch {
                camera = nil
                status = "Could not start the glasses camera: \(error.localizedDescription)"
            }
        }
    }

    private func handleDisplayState(_ state: DisplayState) {
        displayState = state
        switch state {
        case .started:
            status = streamState == .streaming
                ? "JARVIS is ready. Tap the glasses to scan."
                : "Display ready. Waiting for camera…"
            sendReadyIfPossible()
        case .stopping:
            break
        case .stopped:
            sentReadyCard = false
            display = nil
            displayStateToken = nil
        case .starting:
            break
        }
    }

    private func handleStreamState(_ state: StreamState) {
        streamState = state
        switch state {
        case .streaming:
            status = displayState == .started
                ? "JARVIS is ready. Tap the glasses to scan."
                : "Camera ready. Waiting for display…"
            sendReadyIfPossible()
        case .waitingForDevice:
            status = "Camera is waiting for the glasses…"
            sentReadyCard = false
        case .paused:
            status = "Camera stream paused."
            sentReadyCard = false
        case .stopping:
            break
        case .stopped:
            sentReadyCard = false
            streamStateToken = nil
            streamErrorToken = nil
            photoToken = nil
            camera = nil
        case .starting:
            break
        }
    }

    private func handleStreamError(_ error: StreamError) {
        status = "Camera stream error: \(error.localizedDescription)"
        if isProcessing {
            isProcessing = false
        }
    }

    private func handlePhoto(_ data: Data) {
        guard isProcessing else { return }

        lastPhoto = UIImage(data: data)
        status = "Thinking…"
        Task { await sendWorkingToDisplay("Thinking…") }

        Task {
            let uploadData = compressedJPEG(from: data) ?? data

            do {
                let answer = try await backend.ask(
                    imageData: uploadData,
                    token: backendToken
                )
                lastAnswer = answer
                isProcessing = false
                status = "Answer ready. Tap the glasses to scan again."
                await sendAnswerToDisplay(answer)
            } catch {
                isProcessing = false
                let message = error.localizedDescription
                status = "AI error: \(message)"
                await sendErrorToDisplay(message)
            }
        }
    }

    private func compressedJPEG(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.78)
    }

    private func sendReadyIfPossible() {
        guard isReady, !isProcessing, !sentReadyCard else { return }
        sentReadyCard = true

        Task {
            guard let display else { return }
            do {
                try await display.send(
                    JARVISDisplayViews.ready { [weak self] in
                        Task { @MainActor in
                            self?.captureAndAsk()
                        }
                    }
                )
            } catch {
                status = "Display send error: \(error.localizedDescription)"
                sentReadyCard = false
            }
        }
    }

    private func sendWorkingToDisplay(_ message: String) async {
        guard let display, displayState == .started else { return }
        do {
            try await display.send(JARVISDisplayViews.working(message))
        } catch {
            status = "Display send error: \(error.localizedDescription)"
        }
    }

    private func sendAnswerToDisplay(_ answer: String) async {
        guard let display, displayState == .started else { return }
        let compactAnswer = String(answer.prefix(950))

        do {
            try await display.send(
                JARVISDisplayViews.answer(compactAnswer) { [weak self] in
                    Task { @MainActor in
                        self?.captureAndAsk()
                    }
                }
            )
        } catch {
            status = "Display answer error: \(error.localizedDescription)"
        }
    }

    private func sendErrorToDisplay(_ message: String) async {
        guard let display, displayState == .started else { return }
        let compactMessage = String(message.prefix(500))

        do {
            try await display.send(
                JARVISDisplayViews.error(compactMessage) { [weak self] in
                    Task { @MainActor in
                        self?.captureAndAsk()
                    }
                }
            )
        } catch {
            status = "Display error: \(error.localizedDescription)"
        }
    }

    private func finishWithError(_ message: String) {
        isProcessing = false
        status = message
        Task { await sendErrorToDisplay(message) }
    }

    private func disconnectForRegistrationReset() {
        if deviceSession != nil {
            display?.stop()
            camera?.stop()
            deviceSession?.stop()
        }
        clearCapabilityReferences()
        clearSessionReferences()
        cameraPermissionChecked = false
        cameraPermissionGranted = false
        selectedDeviceIdentifier = nil
        hasActiveDevice = false
        sessionState = .idle
        streamState = .stopped
        displayState = .stopped
        lastSessionError = nil
    }

    private func clearCapabilityReferences() {
        displayStateToken = nil
        streamStateToken = nil
        streamErrorToken = nil
        photoToken = nil
        display = nil
        camera = nil
    }

    private func clearSessionReferences() {
        sessionStateToken = nil
        sessionErrorToken = nil
        deviceSession = nil
    }
}
