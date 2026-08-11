@preconcurrency import AVFAudio
import CoreMedia
import Foundation

@MainActor
final class AudioCaptureService: ObservableObject, AudioCapturing {
    @Published private(set) var routeSnapshot: AudioRouteSnapshot = .unavailable
    @Published private(set) var meterSnapshot: AudioMeterSnapshot = .silent
    @Published private(set) var droppedFrameCount = 0
    @Published private(set) var lastRouteEvent = "No route changes"
    @Published private(set) var availableInputNames: [String] = []
    @Published private(set) var detectedUSBInputName: String?
    @Published private(set) var preferredInputName: String?

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
        if !isRunning, !hasConfiguredCategory {
            try? audioSession.setCategory(.record, mode: .measurement)
            hasConfiguredCategory = true
        }
        refreshInputInventory()
        routeSnapshot = makeRouteSnapshot()
    }

    func start() async throws -> AsyncStream<TimedAudioFrame> {
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
        droppedFrameCount = 0
        duplicateChannelEvidence = 0
        clock.reset()

        do {
            try await configureSession()
            try installTapAndStart(using: streamPair.continuation)
            isRunning = true
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
        removeInputTapIfInstalled()
        audioEngine.stop()
        frameContinuation?.finish()
        frameContinuation = nil
        meterSnapshot = .silent
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        refreshRoute()
    }

    private func configureSession() async throws {
        try audioSession.setCategory(.record, mode: .measurement)
        hasConfiguredCategory = true
        try? audioSession.setPreferredSampleRate(48_000)
        try? audioSession.setPreferredIOBufferDuration(0.02)
        try audioSession.setActive(true)

        // Input ports are only authoritative after the category, mode, and active state are set.
        // Give Core Audio a scheduling turn to publish a newly attached USB interface.
        await Task.yield()
        refreshInputInventory()

        if let usbInput = audioSession.availableInputs?.first(where: { $0.portType == .usbAudio }) {
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

    private func installTapAndStart(
        using continuation: AsyncStream<TimedAudioFrame>.Continuation
    ) throws {
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoicesInViewError.microphoneUnavailable
        }

        let frameClock = clock
        let tapBlock = Self.makeTapBlock(
            continuation: continuation,
            frameClock: frameClock,
            sampleRate: inputFormat.sampleRate,
            updateMeters: { [weak self] meters in
                self?.updateMeterSnapshot(meters)
            },
            recordDroppedFrame: { [weak self] in
                self?.droppedFrameCount += 1
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
        if snapshot.channelsAreNearlyIdentical {
            duplicateChannelEvidence = min(12, duplicateChannelEvidence + 1)
        } else {
            duplicateChannelEvidence = max(0, duplicateChannelEvidence - 1)
        }

        var displayed = snapshot
        displayed.channelsAreNearlyIdentical = duplicateChannelEvidence >= 4
        meterSnapshot = displayed
    }

    private func makeRouteSnapshot() -> AudioRouteSnapshot {
        let currentInputs = audioSession.currentRoute.inputs
        let availableInputs = audioSession.availableInputs ?? []
        let input = currentInputs.first
            ?? availableInputs.first

        guard let input else { return .unavailable }

        let kind: InputKind
        switch input.portType {
        case .usbAudio:
            kind = .usb
        case .builtInMic:
            kind = .builtIn
        default:
            kind = .other
        }

        let channels = input.channels ?? []
        let names: [String] = channels.map { channel -> String in
            let name = String(describing: channel.channelName)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Channel \(channel.channelNumber)" : trimmed
        }
        let reportedChannels = audioSession.inputNumberOfChannels
        let channelCount = max(reportedChannels, names.count)

        return AudioRouteSnapshot(
            inputName: input.portName,
            inputKind: kind,
            channelNames: names,
            channelCount: channelCount,
            sampleRate: audioSession.sampleRate,
            inputLatency: audioSession.inputLatency,
            ioBufferDuration: audioSession.ioBufferDuration,
            isConnected: true
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
        isReconfiguring = true

        removeInputTapIfInstalled()
        audioEngine.stop()

        do {
            try await configureSession()
            try installTapAndStart(using: continuation)
            routeSnapshot = makeRouteSnapshot()
        } catch {
            lastRouteEvent = "Route recovery failed: \(error.localizedDescription)"
        }
        isReconfiguring = false
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

    private func refreshInputInventory() {
        let inputs = audioSession.availableInputs ?? []
        availableInputNames = inputs.map { input in
            let kind = input.portType == .usbAudio ? "USB" : input.portType.rawValue
            return "\(input.portName) (\(kind))"
        }
        detectedUSBInputName = inputs.first(where: { $0.portType == .usbAudio })?.portName
        preferredInputName = audioSession.preferredInput?.portName
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
