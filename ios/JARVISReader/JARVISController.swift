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
    private static let autoConnectKey = "jarvisAutoConnect"
    private static let maxCameraRecoveryAttempts = 1
    private static let cameraRecoveryDelayNanoseconds: UInt64 = 450_000_000

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

    private var autoConnectWhenDeviceAppears: Bool {
        didSet {
            UserDefaults.standard.set(autoConnectWhenDeviceAppears, forKey: Self.autoConnectKey)
        }
    }
    private var sentReadyCard = false
    private var lastSessionError: String?
    private var photoCaptureIssued = false
    private var cameraRecoveryAttempts = 0
    private var lastStreamErrorDescription: String?

    init(wearables: WearablesInterface = Wearables.shared) {
        self.wearables = wearables
        self.backendToken = UserDefaults.standard.string(forKey: Self.backendTokenKey) ?? ""
        self.autoConnectWhenDeviceAppears = UserDefaults.standard.object(forKey: Self.autoConnectKey) as? Bool ?? true

        startObservers()
        refresh()
    }

    var isRegistered: Bool {
        registrationState == .registered
    }

    // Ready means the persistent glasses session + display are alive.
    // The camera intentionally stays OFF until the user requests a capture.
    var isReady: Bool {
        sessionState == .started && displayState == .started && cameraPermissionGranted
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
        case .streaming: return "streaming (capture only)"
        case .starting: return "starting capture"
        case .waitingForDevice: return "waiting for device"
        case .stopping: return "stopping capture"
        case .stopped: return "off"
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
                    ? "Registered. Checking your saved camera access…"
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
                    status = "Camera access granted. Camera stays off until capture."
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
            disconnectSessionOnly()
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
        sentReadyCard = false
        photoCaptureIssued = false
        cameraRecoveryAttempts = 0
        lastStreamErrorDescription = nil
        status = "Starting camera for one photo…"
        Task { await sendWorkingToDisplay("Starting camera…") }

        startCameraForCapture()
    }

    func disconnect() {
        autoConnectWhenDeviceAppears = false
        disconnectSessionOnly()
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
                    self.status = "Registered with Meta AI. Restoring setup…"
                    self.updateDevices(Array(wearables.devices))
                    await self.refreshCameraPermission()
                case .registering:
                    self.status = "Registration is in progress…"
                case .available:
                    // Do not erase saved permission/device choices here. DAT can briefly
                    // report a non-registered state while the app/Meta AI link settles.
                    self.status = "Meta registration is available."
                    self.suspendForRegistrationChange()
                case .unavailable:
                    self.status = "Meta registration is currently unavailable."
                    self.suspendForRegistrationChange()
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
            return
        }

        do {
            let result = try await wearables.checkPermissionStatus(.camera)
            cameraPermissionChecked = true
            cameraPermissionGranted = result == .granted

            if cameraPermissionGranted {
                status = deviceSession == nil
                    ? (hasActiveDevice ? "Setup restored. Connecting glasses…" : "Setup restored. Waiting for glasses…")
                    : status

                if autoConnectWhenDeviceAppears {
                    updateDevices(Array(wearables.devices))
                    connectIfPossible()
                }
            } else {
                status = "Camera access needs approval."
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
            status = "Session connected. Starting display…"
            setupDisplay(on: session)
        case .stopping:
            if lastSessionError == nil {
                status = "Stopping glasses session…"
            }
        case .stopped:
            isConnecting = false
            sentReadyCard = false
            stopCaptureCamera()
            clearDisplayReference()
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
        stopCaptureCamera()
        if isProcessing {
            isProcessing = false
        }
    }

    private func setupDisplay(on session: DeviceSession) {
        guard display == nil else { return }

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

    private func handleDisplayState(_ state: DisplayState) {
        displayState = state
        switch state {
        case .started:
            status = "JARVIS is ready. Camera is off until you capture."
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

    private func startCameraForCapture() {
        guard isProcessing,
              sessionState == .started,
              let session = deviceSession,
              camera == nil else {
            if isProcessing && camera != nil {
                status = "Camera is already starting…"
            }
            return
        }

        lastStreamErrorDescription = nil

        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .medium,
            frameRate: 15
        )

        do {
            guard let newCamera = try session.addCamera(config: config) else {
                finishWithError("Could not create the glasses camera.")
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
            stopCaptureCamera()
            finishWithError("Could not start the glasses camera: \(error.localizedDescription)")
        }
    }

    private func handleStreamState(_ state: StreamState) {
        streamState = state

        switch state {
        case .streaming:
            guard isProcessing, !photoCaptureIssued, let camera else { return }
            photoCaptureIssued = true
            status = cameraRecoveryAttempts == 0 ? "Capturing photo…" : "Retrying photo capture…"
            Task { await sendWorkingToDisplay(cameraRecoveryAttempts == 0 ? "Capturing…" : "Retrying capture…") }

            let didStart = camera.stream.capturePhoto(format: .jpeg)
            if !didStart {
                photoCaptureIssued = false
                stopCaptureCamera()
                finishWithError("The glasses could not capture a photo. Try again.")
            }
        case .waitingForDevice:
            status = "Camera is waiting for the glasses…"
        case .paused:
            status = "Camera paused before capture."
        case .stopping:
            break
        case .stopped:
            let streamError = lastStreamErrorDescription
            let captureWasInterrupted = isProcessing && (photoCaptureIssued || streamError != nil)

            // In DAT 0.9 terminal stream errors stop the stream for us. Once the
            // state reaches .stopped, detach the dead Camera before creating a new one.
            stopCaptureCamera()

            if captureWasInterrupted {
                recoverCameraCapture(
                    reason: streamError ?? "Camera stopped before the photo arrived."
                )
            }
        case .starting:
            status = cameraRecoveryAttempts == 0
                ? "Starting camera for one photo…"
                : "Reconnecting camera…"
        }
    }

    private func handleStreamError(_ error: StreamError) {
        let message = error.localizedDescription
        lastStreamErrorDescription = message

        // Do not stop the stream from the error callback. DAT 0.9 owns terminal
        // teardown and reports the authoritative result through StreamState.
        if isProcessing {
            status = "Camera stream issue: \(message)"
            Task { await sendWorkingToDisplay("Camera interrupted…") }
        } else {
            status = "Camera error: \(message)"
        }
    }

    private func recoverCameraCapture(reason: String) {
        guard isProcessing else { return }

        guard cameraRecoveryAttempts < Self.maxCameraRecoveryAttempts else {
            finishWithError("Camera error after retry: \(reason)")
            return
        }

        cameraRecoveryAttempts += 1
        lastStreamErrorDescription = nil
        photoCaptureIssued = false
        status = "Camera stream ended. Reconnecting…"

        Task {
            await sendWorkingToDisplay("Reconnecting camera…")
            try? await Task.sleep(nanoseconds: Self.cameraRecoveryDelayNanoseconds)

            guard isProcessing else { return }
            guard sessionState == .started, deviceSession != nil else {
                finishWithError("Camera connection was lost. Tap to try again.")
                return
            }

            status = "Retrying camera capture…"
            startCameraForCapture()
        }
    }

    private func handlePhoto(_ data: Data) {
        guard isProcessing else { return }

        // The privacy light should go out as soon as the still image arrives.
        photoCaptureIssued = false
        lastStreamErrorDescription = nil
        stopCaptureCamera()

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

    private func stopCaptureCamera() {
        let activeCamera = camera
        clearCameraReferences()
        streamState = .stopped
        photoCaptureIssued = false
        lastStreamErrorDescription = nil
        activeCamera?.stop()
    }

    private func compressedJPEG(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.78)
    }

    private func sendReadyIfPossible() {
        guard isReady, camera == nil, !isProcessing, !sentReadyCard else { return }
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
        stopCaptureCamera()
        isProcessing = false
        status = message
        Task { await sendErrorToDisplay(message) }
    }

    private func suspendForRegistrationChange() {
        sentReadyCard = false
        isProcessing = false
        stopCaptureCamera()
        display?.stop()
        deviceSession?.stop()
        clearDisplayReference()
        clearSessionReferences()
        sessionState = .idle
        streamState = .stopped
        displayState = .stopped
        lastSessionError = nil
        cameraPermissionChecked = false
        // Deliberately preserve the last known permission flag, selected device,
        // and auto-connect preference so a transient DAT state does not make the
        // user redo setup. Permission is verified again when registration returns.
    }

    private func disconnectSessionOnly() {
        sentReadyCard = false
        isProcessing = false
        stopCaptureCamera()
        display?.stop()
        deviceSession?.stop()
        clearDisplayReference()
        clearSessionReferences()
        sessionState = .idle
        streamState = .stopped
        displayState = .stopped
        lastSessionError = nil
    }

    private func clearCameraReferences() {
        streamStateToken = nil
        streamErrorToken = nil
        photoToken = nil
        camera = nil
    }

    private func clearDisplayReference() {
        displayStateToken = nil
        display = nil
    }

    private func clearSessionReferences() {
        sessionStateToken = nil
        sessionErrorToken = nil
        deviceSession = nil
    }
}
