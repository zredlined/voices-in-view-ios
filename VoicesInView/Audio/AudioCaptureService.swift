@preconcurrency import AVFAudio
import CoreMedia
import Foundation

struct BluetoothInputChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

@MainActor
final class AudioCaptureService: ObservableObject, AudioCapturing {
    @Published private(set) var routeSnapshot: AudioRouteSnapshot = .unavailable
    @Published private(set) var meterSnapshot: AudioMeterSnapshot = .silent
    @Published private(set) var droppedFrameCount = 0
    @Published private(set) var lastRouteEvent = "No route changes"
    @Published private(set) var availableInputNames: [String] = []
    @Published private(set) var detectedUSBInputName: String?
    @Published private(set) var preferredInputName: String?
    @Published private(set) var selectedInputName: String?
    @Published private(set) var selectedInputKind: InputKind?
    @Published private(set) var bluetoothInputChoices: [BluetoothInputChoice] = []
    @Published private(set) var captureProfile: AudioCaptureProfile = .standard
    @Published private(set) var receivedBufferCount = 0
    @Published private(set) var nonSilentBufferCount = 0
    @Published private(set) var captureFormatDescription = "Not active"

    private let audioSession = AVAudioSession.sharedInstance()
    private var audioEngine = AVAudioEngine()
    private let clock = AudioFrameClock()
    private var frameContinuation: AsyncStream<TimedAudioFrame>.Continuation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var isRunning = false
    private var isReconfiguring = false
    private var hasInstalledInputTap = false
    private var hasConfiguredCategory = false
    private var duplicateChannelEvidence = 0
    private var negotiatedChannelCount = 0
    private var negotiatedSampleRate: Double = 0
    private var didLogFirstBuffer = false
    private var didLogFirstSignal = false
    private var activeRouteFingerprint: String?
    private var totalReceivedBufferCount = 0
    private var totalNonSilentBufferCount = 0
    private var lastMeterPublicationTime: TimeInterval = 0
    private var lastDiagnosticPublicationTime: TimeInterval = 0
    private var isPreviewCapture = false
    private var manuallySelectedBluetoothInputUID: String?

    init() {
        installNotifications()
        refreshRoute()
    }

    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func refreshRoute() {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-screenshot-fixture") {
            return
        }
#endif
        if !isRunning, !hasConfiguredCategory {
            try? audioSession.setCategory(.record, mode: .measurement)
            hasConfiguredCategory = true
        }
        refreshInputInventory()
        if !isRunning {
            try? selectInputForCurrentProfile()
        }
        routeSnapshot = makeRouteSnapshot()
    }

    func selectCaptureProfile(_ profile: AudioCaptureProfile) {
        guard !isRunning else { return }
        captureProfile = profile
        if profile == .airPodsFarField, selectedInputKind != .bluetooth {
            selectedInputName = nil
            selectedInputKind = nil
        }

        do {
            try configureAudioCategory()
            refreshInputInventory()
            try selectInputForCurrentProfile()
            lastRouteEvent = "Requested \(profile.requestedTuningDescription)"
        } catch {
            lastRouteEvent = "Audio setup failed: \(error.localizedDescription)"
        }
        refreshInputInventory()
        routeSnapshot = makeRouteSnapshot()
    }

    func selectBluetoothInput(id: String) {
        guard !isRunning,
              captureProfile == .airPodsFarField,
              let choice = bluetoothInputChoices.first(where: { $0.id == id })
        else { return }

        manuallySelectedBluetoothInputUID = choice.id
        selectedInputName = choice.name
        selectedInputKind = .bluetooth

        guard let input = audioSession.availableInputs?.first(where: {
            $0.uid == id && $0.portType == .bluetoothHFP
        }) else {
            lastRouteEvent = "Will use \(choice.name) when listening"
            return
        }

        do {
            try applySelectedInput(input)
            lastRouteEvent = "Selected \(input.portName)"
            routeSnapshot = makeRouteSnapshot()
        } catch {
            lastRouteEvent = "Couldn't select \(input.portName): \(error.localizedDescription)"
        }
    }

#if DEBUG
    func configureForScreenshot(
        route: AudioRouteSnapshot,
        meters: AudioMeterSnapshot
    ) {
        routeSnapshot = route
        meterSnapshot = meters
        availableInputNames = [route.inputName]
        detectedUSBInputName = route.inputKind == .usb ? route.inputName : nil
        preferredInputName = route.inputName
    }
#endif

    func start() async throws -> AsyncStream<TimedAudioFrame> {
        try await startCapture(isPreview: false)
    }

    func startPreview() async throws -> AsyncStream<TimedAudioFrame> {
        try await startCapture(isPreview: true)
    }

    func promotePreviewToCaptioning() {
        isPreviewCapture = false
        droppedFrameCount = 0
    }

    private func startCapture(isPreview: Bool) async throws -> AsyncStream<TimedAudioFrame> {
        if isRunning {
            stop()
        }

        guard await requestPermission() else {
            throw VoicesInViewError.microphoneDenied
        }

        let streamPair = AsyncStream.makeStream(
            of: TimedAudioFrame.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        frameContinuation = streamPair.continuation
        isPreviewCapture = isPreview
        droppedFrameCount = 0
        duplicateChannelEvidence = 0
        receivedBufferCount = 0
        nonSilentBufferCount = 0
        totalReceivedBufferCount = 0
        totalNonSilentBufferCount = 0
        lastMeterPublicationTime = 0
        lastDiagnosticPublicationTime = 0
        captureFormatDescription = "Preparing"
        didLogFirstBuffer = false
        didLogFirstSignal = false
        clock.reset()

        do {
            try await configureSession()
            try installTapAndStart(using: streamPair.continuation)
            isRunning = true
            activeRouteFingerprint = makeRouteFingerprint()
            routeSnapshot = makeRouteSnapshot()
            return streamPair.stream
        } catch {
            streamPair.continuation.finish()
            frameContinuation = nil
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw VoicesInViewError.audioConfigurationFailed(error.localizedDescription)
        }
    }

    func stop() {
        isRunning = false
        isPreviewCapture = false
        activeRouteFingerprint = nil
        negotiatedChannelCount = 0
        negotiatedSampleRate = 0
        removeInputTapIfInstalled()
        audioEngine.stop()
        frameContinuation?.finish()
        frameContinuation = nil
        meterSnapshot = .silent
        captureFormatDescription = "Not active"
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        refreshRoute()
    }

    private func configureSession() async throws {
        try configureAudioCategory()
        refreshInputInventory()
        try selectInputForCurrentProfile()
        try? audioSession.setPreferredSampleRate(48_000)
        try? audioSession.setPreferredIOBufferDuration(0.02)
        try audioSession.setActive(true)

        // Input ports are only authoritative after the category, mode, and active state are set.
        // Give Core Audio a scheduling turn to publish a newly attached USB interface.
        await Task.yield()
        refreshInputInventory(preserveBluetoothChoices: false)
        try selectInputForCurrentProfile(clearUnavailableAirPods: true)

        if captureProfile.requiresAirPods {
            // Bluetooth routing can settle after activation. Give the automatically selected
            // AirPods a bounded window to become the active HFP microphone.
            for _ in 0 ..< 10 where !currentRouteUsesSelectedBluetoothMicrophone {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard currentRouteUsesSelectedBluetoothMicrophone else {
                throw VoicesInViewError.airPodsNotActive
            }
        } else if captureProfile == .usb {
            guard let usbInput = audioSession.availableInputs?.first(where: {
                $0.portType == .usbAudio
            }) else {
                throw VoicesInViewError.microphoneUnavailable
            }
            try audioSession.setPreferredInput(usbInput)

            // A preferred input is a routing request, not proof that the route changed. Wait a
            // bounded amount of time before constructing AVAudioEngine so it gets the USB format.
            for _ in 0 ..< 5 where !currentRouteUsesUSB {
                try await Task.sleep(for: .milliseconds(40))
            }

            if !currentRouteUsesUSB {
                lastRouteEvent = "DJI is available, but iOS kept the iPhone microphone"
            }
        }

        let desiredChannels = min(2, max(1, audioSession.maximumInputNumberOfChannels))
        try? audioSession.setPreferredInputNumberOfChannels(desiredChannels)
        refreshInputInventory()
    }

    private func configureAudioCategory() throws {
        switch captureProfile {
        case .standard, .usb:
            try audioSession.setCategory(.record, mode: .measurement)
        case .airPodsFarField:
            guard #available(iOS 26.2, *) else {
                throw VoicesInViewError.audioConfigurationFailed(
                    "Far-field capture requires iOS 26.2 or later."
                )
            }
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP, .farFieldInput, .mixWithOthers]
            )
        }
        hasConfiguredCategory = true
    }

    private func installTapAndStart(
        using continuation: AsyncStream<TimedAudioFrame>.Continuation
    ) throws {
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoicesInViewError.microphoneUnavailable
        }
        negotiatedChannelCount = Int(inputFormat.channelCount)
        negotiatedSampleRate = inputFormat.sampleRate
        captureFormatDescription = Self.describe(inputFormat)
        print(
            "Audio capture starting | profile=\(captureProfile.rawValue) "
                + "input=\(audioSession.currentRoute.inputs.map(\.portName)) "
                + "output=\(audioSession.currentRoute.outputs.map(\.portName)) "
                + "format=\(captureFormatDescription)"
        )

        let frameClock = clock
        let tapBlock = Self.makeTapBlock(
            continuation: continuation,
            frameClock: frameClock,
            sampleRate: inputFormat.sampleRate,
            updateMeters: { [weak self] meters in
                self?.updateMeterSnapshot(meters)
            },
            recordDroppedFrame: { [weak self] in
                self?.recordDroppedFrameIfNeeded()
            }
        )
        inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(max(256, Int(inputFormat.sampleRate * 0.02))),
            format: inputFormat,
            block: tapBlock
        )
        hasInstalledInputTap = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            removeInputTapIfInstalled()
            throw error
        }
    }

    /// AVAudioEngine invokes tap blocks on its real-time queue. Construct the block from a
    /// nonisolated context so Swift does not inherit this service's MainActor precondition.
    nonisolated private static func makeTapBlock(
        continuation: AsyncStream<TimedAudioFrame>.Continuation,
        frameClock: AudioFrameClock,
        sampleRate: Double,
        updateMeters: @escaping @MainActor @Sendable (AudioMeterSnapshot) -> Void,
        recordDroppedFrame: @escaping @MainActor @Sendable () -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, audioTime in
            let meters = AudioMixer.meterSnapshot(for: buffer)
            let monoBuffer = AudioMixer.downmixToMono(buffer)

            Task { @MainActor in
                updateMeters(meters)
            }

            guard let monoBuffer else { return }
            let startTime = frameClock.relativeTime(
                sampleTime: audioTime.sampleTime,
                sampleRate: sampleRate
            )
            let result = continuation.yield(
                TimedAudioFrame(buffer: monoBuffer, startTime: startTime)
            )

            if case .dropped = result {
                Task { @MainActor in
                    recordDroppedFrame()
                }
            }
        }
    }

    private func removeInputTapIfInstalled() {
        guard hasInstalledInputTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        hasInstalledInputTap = false
    }

    private func updateMeterSnapshot(_ snapshot: AudioMeterSnapshot) {
        totalReceivedBufferCount += 1
        let isFirstBuffer = !didLogFirstBuffer
        if isFirstBuffer {
            didLogFirstBuffer = true
            print("Audio capture received its first buffer")
        }

        let containsSignal = snapshot.strongestLevel > 0.01
        let isFirstSignal = containsSignal && !didLogFirstSignal
        if containsSignal {
            totalNonSilentBufferCount += 1
            if isFirstSignal {
                didLogFirstSignal = true
                print("Audio capture received its first non-silent buffer")
            }
        }

        // The audio tap normally fires around 50 times per second. Publishing three separate
        // observable properties for every buffer causes the whole home screen to be invalidated
        // more than 100 times per second, which is especially noticeable while Bluetooth routes.
        let now = ProcessInfo.processInfo.systemUptime
        guard isFirstBuffer || isFirstSignal || now - lastMeterPublicationTime >= 1.0 / 15.0 else {
            return
        }
        lastMeterPublicationTime = now
        if isFirstBuffer || isFirstSignal || now - lastDiagnosticPublicationTime >= 0.5 {
            lastDiagnosticPublicationTime = now
            receivedBufferCount = totalReceivedBufferCount
            nonSilentBufferCount = totalNonSilentBufferCount
        }

        if snapshot.channelsAreNearlyIdentical {
            duplicateChannelEvidence = min(12, duplicateChannelEvidence + 1)
        } else {
            duplicateChannelEvidence = max(0, duplicateChannelEvidence - 1)
        }

        var displayed = snapshot
        displayed.channelsAreNearlyIdentical = duplicateChannelEvidence >= 4
        meterSnapshot = displayed
    }

    private func recordDroppedFrameIfNeeded() {
        guard !isPreviewCapture else { return }
        droppedFrameCount += 1
    }

    nonisolated private static func describe(_ format: AVAudioFormat) -> String {
        let layout = format.isInterleaved ? "interleaved" : "non-interleaved"
        return "\(Int(format.sampleRate)) Hz · \(format.channelCount) ch · \(format.commonFormat) · \(layout)"
    }

    private func makeRouteSnapshot() -> AudioRouteSnapshot {
        let currentInputs = audioSession.currentRoute.inputs
        let availableInputs = audioSession.availableInputs ?? []
        let input = currentInputs.first
            ?? availableInputs.first

        guard let input else { return .unavailable }

        let kind = Self.inputKind(for: input.portType)

        let bluetooth = input.bluetoothMicrophoneExtension

        let channels = input.channels ?? []
        let names: [String] = channels.map { channel -> String in
            let name = String(describing: channel.channelName)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Channel \(channel.channelNumber)" : trimmed
        }
        let reportedChannels = audioSession.inputNumberOfChannels
        let channelCount = max(negotiatedChannelCount, max(reportedChannels, names.count))
        let sampleRate = negotiatedSampleRate > 0
            ? negotiatedSampleRate
            : (channelCount > 0 ? audioSession.sampleRate : 0)

        return AudioRouteSnapshot(
            inputName: input.portName,
            inputKind: kind,
            channelNames: names,
            channelCount: channelCount,
            sampleRate: sampleRate,
            inputLatency: audioSession.inputLatency,
            ioBufferDuration: audioSession.ioBufferDuration,
            isConnected: true,
            outputNames: audioSession.currentRoute.outputs.map(\.portName),
            bluetoothFarFieldSupported: bluetooth?.farFieldCapture.isSupported ?? false,
            bluetoothFarFieldEnabled: bluetooth?.farFieldCapture.isEnabled ?? false
        )
    }

    private func installNotifications() {
        let routeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let description = Self.describe(reason)
            Task { @MainActor [weak self] in
                await self?.handleRouteChange(description: description)
            }
        }

        let interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor [weak self] in
                self?.handleInterruption(type)
            }
        }

        let inputsToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.availableInputsChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastRouteEvent = "Available microphones changed"
                self.refreshRoute()
                if self.isRunning {
                    await self.handleRouteChange(description: "Available microphones changed")
                }
            }
        }

        let mediaResetToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasConfiguredCategory = false
                await self.handleRouteChange(description: "Audio services restarted")
            }
        }

        notificationTokens = [routeToken, interruptionToken, inputsToken, mediaResetToken]
    }

    private func handleRouteChange(description: String) async {
        lastRouteEvent = description
        refreshInputInventory()
        routeSnapshot = makeRouteSnapshot()

        guard isRunning, !isReconfiguring, let continuation = frameContinuation else { return }

        // Activating and starting an AVAudioEngine can itself emit category/route-configuration
        // notifications. Rebuilding the engine for those no-op notifications creates a restart
        // loop on Bluetooth HFP routes before useful microphone buffers can arrive.
        let routeFingerprint = makeRouteFingerprint()
        guard routeFingerprint != activeRouteFingerprint else { return }
        isReconfiguring = true

        removeInputTapIfInstalled()
        audioEngine.stop()

        do {
            try await configureSession()
            try installTapAndStart(using: continuation)
            activeRouteFingerprint = makeRouteFingerprint()
            routeSnapshot = makeRouteSnapshot()
        } catch {
            lastRouteEvent = "Route recovery failed: \(error.localizedDescription)"
        }
        isReconfiguring = false
    }

    private func makeRouteFingerprint() -> String {
        let inputs = audioSession.currentRoute.inputs.map {
            "\($0.uid)|\($0.portType.rawValue)|\($0.portName)"
        }
        let outputs = audioSession.currentRoute.outputs.map {
            "\($0.uid)|\($0.portType.rawValue)|\($0.portName)"
        }
        return (inputs + outputs).joined(separator: ";")
            + "|\(audioSession.sampleRate)|\(audioSession.inputNumberOfChannels)"
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            lastRouteEvent = "Audio interrupted"
        case .ended:
            lastRouteEvent = "Audio interruption ended"
            Task { await handleRouteChange(description: "Audio resumed") }
        case nil:
            break
        @unknown default:
            lastRouteEvent = "Unknown audio interruption"
        }
    }

    private var currentRouteUsesUSB: Bool {
        audioSession.currentRoute.inputs.contains { $0.portType == .usbAudio }
    }

    private var currentRouteUsesSelectedBluetoothMicrophone: Bool {
        audioSession.currentRoute.inputs.contains { input in
            guard input.portType == .bluetoothHFP else { return false }
            return selectedInputName == nil || input.portName == selectedInputName
        }
    }

    private func refreshInputInventory(preserveBluetoothChoices: Bool = true) {
        let inputs = audioSession.availableInputs ?? []
        availableInputNames = inputs.map { input in
            let kind: String
            switch input.portType {
            case .usbAudio: kind = "USB"
            case .bluetoothHFP: kind = "Bluetooth microphone"
            default: kind = input.portType.rawValue
            }
            return "\(input.portName) (\(kind))"
        }
        let discoveredBluetoothInputs = inputs
            .filter { $0.portType == .bluetoothHFP }
            .map { BluetoothInputChoice(id: $0.uid, name: $0.portName) }
        if !discoveredBluetoothInputs.isEmpty || !preserveBluetoothChoices {
            bluetoothInputChoices = discoveredBluetoothInputs
        }
        detectedUSBInputName = inputs.first(where: { $0.portType == .usbAudio })?.portName
        let preferredInput = audioSession.preferredInput
        preferredInputName = preferredInput?.portName

        if selectedInputName == nil,
           let initialInput = preferredInput ?? audioSession.currentRoute.inputs.first
        {
            selectedInputName = initialInput.portName
            selectedInputKind = Self.inputKind(for: initialInput.portType)
        }
    }

    private func selectInputForCurrentProfile(clearUnavailableAirPods: Bool = false) throws {
        let inputs = audioSession.availableInputs ?? []
        let selectedInput: AVAudioSessionPortDescription?

        switch captureProfile {
        case .standard:
            selectedInput = inputs.first(where: { $0.portType == .builtInMic })
                ?? audioSession.currentRoute.inputs.first
        case .usb:
            selectedInput = inputs.first(where: { $0.portType == .usbAudio })
        case .airPodsFarField:
            let manualBluetooth = manuallySelectedBluetoothInputUID.flatMap { uid in
                inputs.first(where: { $0.uid == uid && $0.portType == .bluetoothHFP })
            }
            if clearUnavailableAirPods,
               manuallySelectedBluetoothInputUID != nil,
               manualBluetooth == nil
            {
                manuallySelectedBluetoothInputUID = nil
            }

            let outputNames = Set(audioSession.currentRoute.outputs.map(\.portName))
            let activeOutputBluetooth = inputs.first(where: {
                $0.portType == .bluetoothHFP && outputNames.contains($0.portName)
            })
            let preferredBluetooth = audioSession.preferredInput.flatMap { preferred in
                inputs.first(where: { $0.uid == preferred.uid && $0.portType == .bluetoothHFP })
            }
            selectedInput = manualBluetooth
                ?? activeOutputBluetooth
                ?? preferredBluetooth
                ?? inputs.first(where: { $0.portType == .bluetoothHFP })
        }

        guard let selectedInput else {
            if captureProfile.requiresAirPods, clearUnavailableAirPods {
                selectedInputName = nil
                selectedInputKind = nil
            }
            return
        }

        try applySelectedInput(selectedInput)
    }

    private func applySelectedInput(_ selectedInput: AVAudioSessionPortDescription) throws {
        try audioSession.setPreferredInput(selectedInput)
        selectedInputName = selectedInput.portName
        selectedInputKind = Self.inputKind(for: selectedInput.portType)
        preferredInputName = audioSession.preferredInput?.portName
    }

    nonisolated private static func inputKind(for portType: AVAudioSession.Port) -> InputKind {
        switch portType {
        case .usbAudio: .usb
        case .builtInMic: .builtIn
        case .bluetoothHFP: .bluetooth
        default: .other
        }
    }

    nonisolated private static func describe(
        _ reason: AVAudioSession.RouteChangeReason?
    ) -> String {
        switch reason {
        case .newDeviceAvailable: "Microphone connected"
        case .oldDeviceUnavailable: "Microphone disconnected — using available input"
        case .categoryChange: "Audio configuration changed"
        case .override: "Audio route changed"
        case .routeConfigurationChange: "Audio route reconfigured"
        case .wakeFromSleep: "Audio resumed"
        case .noSuitableRouteForCategory: "No suitable microphone route"
        case .unknown, .none: "Audio route changed"
        @unknown default: "Audio route changed"
        }
    }
}
