import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var sessionMode: SessionMode {
        didSet { defaults.set(sessionMode.rawValue, forKey: DefaultsKey.sessionMode) }
    }
    @Published var captionFontSize: Double {
        didSet { defaults.set(captionFontSize, forKey: DefaultsKey.captionFontSize) }
    }
    @Published private(set) var modelReadiness: ModelReadiness = .checking
    @Published private(set) var visibleSegments: [CaptionSegment] = []
    @Published private(set) var currentSession: CaptionSession?
    @Published private(set) var completedSession: CaptionSession?
    @Published private(set) var isSessionActive = false
    @Published private(set) var isTestingMicrophones = false
    @Published private(set) var isPreparingMicrophoneTest = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var firstCaptionLatency: TimeInterval?
    @Published private(set) var history: [CaptionSession] = []
    @Published var errorMessage: String?
    @Published var routeBanner: String?

    let audioCapture: AudioCaptureService
    let screenshotFixture: String?

    private enum DefaultsKey {
        static let sessionMode = "sessionMode"
        static let captionFontSize = "captionFontSize"
    }

    private let defaults: UserDefaults
    private let transcriptionEngine: any LiveTranscriptionEngine
    private let savedRepository: any SessionRepository
    private let ephemeralRepository: EphemeralSessionRepository
    private var activeRepository: (any SessionRepository)?
    private let locale = Locale(identifier: "en-US")
    private var timeline = CaptionTimelineReducer()
    private var captionTask: Task<Void, Never>?
    private var microphoneTestFrames: AsyncStream<TimedAudioFrame>?
    private var microphoneTestRequestID = UUID()
    private var cancellables: Set<AnyCancellable> = []
    private var firstSpeechDetectedAt: ContinuousClock.Instant?
    private var previousInputKind: InputKind = .unavailable
    private var screenshotTranscript: SessionTranscript?

    init(
        defaults: UserDefaults = .standard,
        audioCapture: AudioCaptureService? = nil,
        transcriptionEngine: (any LiveTranscriptionEngine)? = nil,
        savedRepository: (any SessionRepository)? = nil,
        ephemeralRepository: EphemeralSessionRepository = EphemeralSessionRepository()
    ) {
        self.defaults = defaults
        self.audioCapture = audioCapture ?? AudioCaptureService()
        self.transcriptionEngine = transcriptionEngine ?? AppleSpeechEngine()
        self.savedRepository = savedRepository ?? SavedSessionRepository()
        self.ephemeralRepository = ephemeralRepository
#if DEBUG
        self.screenshotFixture = Self.requestedScreenshotFixture()
#else
        self.screenshotFixture = nil
#endif

        if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
            defaults.removeObject(forKey: DefaultsKey.sessionMode)
            defaults.removeObject(forKey: DefaultsKey.captionFontSize)
        }

        let storedMode = defaults.string(forKey: DefaultsKey.sessionMode)
            .flatMap(SessionMode.init(rawValue:))
        sessionMode = storedMode ?? .ghost

        let storedSize = defaults.double(forKey: DefaultsKey.captionFontSize)
        captionFontSize = storedSize == 0 ? 36 : min(72, max(24, storedSize))

        observeAudioState()
        configureScreenshotFixtureIfNeeded()
    }

    func refreshModelReadiness() async {
        guard screenshotFixture == nil else { return }
        modelReadiness = .checking
        modelReadiness = await transcriptionEngine.readiness(for: locale)
    }

    func refreshHistory() async {
        guard screenshotFixture == nil else { return }
        do {
            history = try await savedRepository.list()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startCaptions() async {
        guard !isSessionActive, !isStarting else { return }
        isStarting = true
        completedSession = nil
        errorMessage = nil
        routeBanner = nil
        timeline.reset()
        visibleSegments = []
        firstCaptionLatency = nil
        firstSpeechDetectedAt = nil

        let repository: any SessionRepository = sessionMode == .saved
            ? savedRepository
            : ephemeralRepository
        var session = CaptionSession(mode: sessionMode)
        var didBeginSession = false

        do {
            let readiness = await transcriptionEngine.readiness(for: locale)
            if readiness != .ready {
                modelReadiness = .downloading
                try await transcriptionEngine.prepare(locale: locale)
                modelReadiness = .ready
            }

            try await repository.begin(session)
            didBeginSession = true
            activeRepository = repository

            let frames: AsyncStream<TimedAudioFrame>
            if let runningTestFrames = takeMicrophoneTestFrames() {
                // Keep the already-negotiated AirPods route alive. Tearing the mic check down
                // here makes iOS switch Bluetooth modes a second time before captions can start.
                frames = runningTestFrames
            } else {
                frames = try await audioCapture.start()
            }
            let route = audioCapture.routeSnapshot
            session.inputName = route.inputName
            session.channelCount = route.channelCount
            try await repository.updateRoute(
                sessionID: session.id,
                inputName: route.inputName,
                channelCount: route.channelCount
            )

            let updates = try await transcriptionEngine.start(
                frames: frames,
                channel: .group,
                locale: locale
            )

            currentSession = session
            isSessionActive = true
            previousInputKind = route.inputKind
            UIApplication.shared.isIdleTimerDisabled = true

            captionTask = Task { [weak self] in
                do {
                    for try await update in updates {
                        guard let self, !Task.isCancelled else { return }
                        await self.receive(update)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    await self.handleCaptionFailure(error)
                }
            }
        } catch {
            if isTestingMicrophones || isPreparingMicrophoneTest {
                stopMicrophoneTest()
            } else {
                audioCapture.stop()
            }
            await transcriptionEngine.cancel()
            if didBeginSession {
                try? await repository.delete(sessionID: session.id)
            }
            activeRepository = nil
            currentSession = nil
            isSessionActive = false
            UIApplication.shared.isIdleTimerDisabled = false
            modelReadiness = await transcriptionEngine.readiness(for: locale)
            errorMessage = error.localizedDescription
        }

        isStarting = false
    }

    func toggleMicrophoneTest() async {
        guard !isPreparingMicrophoneTest else { return }
        if isTestingMicrophones {
            stopMicrophoneTest()
            return
        }

        let requestID = UUID()
        microphoneTestRequestID = requestID
        isPreparingMicrophoneTest = true
        errorMessage = nil
        do {
            let frames = try await audioCapture.startPreview()
            guard microphoneTestRequestID == requestID else {
                audioCapture.stop()
                return
            }
            microphoneTestFrames = frames
            isTestingMicrophones = true
        } catch {
            audioCapture.stop()
            isTestingMicrophones = false
            errorMessage = error.localizedDescription
        }
        if microphoneTestRequestID == requestID {
            isPreparingMicrophoneTest = false
        }
    }

    func selectCaptureProfile(_ profile: AudioCaptureProfile) {
        if isTestingMicrophones || isPreparingMicrophoneTest {
            stopMicrophoneTest()
        }
        audioCapture.selectCaptureProfile(profile)
    }

    func stopMicrophoneTest() {
        microphoneTestRequestID = UUID()
        isPreparingMicrophoneTest = false
        isTestingMicrophones = false
        microphoneTestFrames = nil
        audioCapture.stop()
    }

    private func takeMicrophoneTestFrames() -> AsyncStream<TimedAudioFrame>? {
        guard isTestingMicrophones, let frames = microphoneTestFrames else { return nil }
        print("Reusing active microphone test stream for captions")
        audioCapture.promotePreviewToCaptioning()
        microphoneTestFrames = nil
        isTestingMicrophones = false
        return frames
    }

    func stopCaptions() async {
        guard isSessionActive, !isStopping else { return }
        isStopping = true
        let session = currentSession
        let endedAt = Date()
        // Mark the session inactive before deactivating its AirPods route so the resulting
        // notification isn't mistaken for an unexpected disconnect.
        isSessionActive = false
        audioCapture.stop()
        await transcriptionEngine.finish()

        let task = captionTask
        captionTask = nil
        await task?.value

        if let session, let activeRepository {
            do {
                try await activeRepository.finish(sessionID: session.id, endedAt: endedAt)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if session?.mode == .ghost {
            await ephemeralRepository.removeAll()
        }

        currentSession = nil
        activeRepository = nil
        isStopping = false
        UIApplication.shared.isIdleTimerDisabled = false
        await refreshHistory()

        if var session, session.mode == .saved {
            session.endedAt = endedAt
            completedSession = (try? await savedRepository.load(sessionID: session.id).session)
                ?? session
        }
    }

    func loadTranscript(_ session: CaptionSession) async throws -> SessionTranscript {
        if let screenshotTranscript, screenshotTranscript.session.id == session.id {
            return screenshotTranscript
        }
        return try await savedRepository.load(sessionID: session.id)
    }

    func delete(_ session: CaptionSession) async {
        do {
            try await savedRepository.delete(sessionID: session.id)
            if completedSession?.id == session.id {
                completedSession = nil
            }
            await refreshHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func increaseFontSize() {
        captionFontSize = min(72, captionFontSize + 6)
    }

    func decreaseFontSize() {
        captionFontSize = max(24, captionFontSize - 6)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func clearError() {
        errorMessage = nil
    }

    func dismissCompletedSession() {
        completedSession = nil
    }

    private func receive(_ update: CaptionUpdate) async {
        if firstCaptionLatency == nil, let firstSpeechDetectedAt {
            firstCaptionLatency = firstSpeechDetectedAt.duration(to: .now).seconds
        }

        let newFinal = timeline.apply(update)
        visibleSegments = timeline.visibleSegments

        if let newFinal, let session = currentSession, let activeRepository {
            do {
                try await activeRepository.append(newFinal, to: session.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleCaptionFailure(_ error: Error) async {
        guard isSessionActive else { return }
        errorMessage = error.localizedDescription
        audioCapture.stop()
        await transcriptionEngine.cancel()
        if let session = currentSession, let activeRepository {
            try? await activeRepository.finish(sessionID: session.id, endedAt: Date())
        }
        if currentSession?.mode == .ghost {
            await ephemeralRepository.removeAll()
        }
        currentSession = nil
        activeRepository = nil
        isSessionActive = false
        UIApplication.shared.isIdleTimerDisabled = false
        await refreshHistory()
    }

    private func observeAudioState() {
        audioCapture.$meterSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meter in
                guard let self, self.isSessionActive else { return }
                if self.firstSpeechDetectedAt == nil, meter.strongestLevel > 0.22 {
                    self.firstSpeechDetectedAt = .now
                }
            }
            .store(in: &cancellables)

        audioCapture.$routeSnapshot
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] route in
                guard let self else { return }
                Task { @MainActor in
                    await self.routeDidChange(route)
                }
            }
            .store(in: &cancellables)
    }

    private func configureScreenshotFixtureIfNeeded() {
#if DEBUG
        guard let screenshotFixture else { return }

        modelReadiness = .ready
        previousInputKind = .usb
        audioCapture.configureForScreenshot(
            route: AudioRouteSnapshot(
                inputName: "DJI Wireless Mic Rx",
                inputKind: .usb,
                channelNames: ["Left", "Right"],
                channelCount: 2,
                sampleRate: 48_000,
                inputLatency: 0.02,
                ioBufferDuration: 0.02,
                isConnected: true
            ),
            meters: AudioMeterSnapshot(
                rms: [0.42, 0.31],
                peak: [0.68, 0.54],
                clippedChannels: [],
                channelsAreNearlyIdentical: false
            )
        )

        let segments = Self.screenshotSegments
        let session = Self.screenshotSession

        switch screenshotFixture {
        case "live":
            currentSession = CaptionSession(
                id: session.id,
                startedAt: session.startedAt,
                localeIdentifier: session.localeIdentifier,
                mode: .ghost,
                inputName: session.inputName,
                channelCount: session.channelCount
            )
            visibleSegments = segments
            isSessionActive = true
        case "saved":
            completedSession = session
            screenshotTranscript = SessionTranscript(session: session, segments: segments)
        default:
            sessionMode = .ghost
        }
#endif
    }

#if DEBUG
    private static func requestedScreenshotFixture() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-screenshot-fixture"),
              arguments.indices.contains(flagIndex + 1)
        else { return nil }
        return arguments[flagIndex + 1]
    }

    private static let screenshotSession = CaptionSession(
        id: UUID(uuidString: "71A84213-4FCE-4925-90D6-F705117BCE75")!,
        startedAt: Date(timeIntervalSinceReferenceDate: 807_303_600),
        endedAt: Date(timeIntervalSinceReferenceDate: 807_303_672),
        mode: .saved,
        inputName: "DJI Wireless Mic Rx",
        channelCount: 2,
        openingExcerpt: "Dinner will be ready in about ten minutes."
    )

    private static let screenshotSegments = [
        CaptionSegment(
            channel: .group,
            startTime: 0,
            endTime: 3.2,
            text: "Dinner will be ready in about ten minutes.",
            isFinal: true
        ),
        CaptionSegment(
            channel: .group,
            startTime: 3.5,
            endTime: 7.1,
            text: "Come into the kitchen whenever you're ready.",
            isFinal: true
        ),
        CaptionSegment(
            channel: .group,
            startTime: 7.4,
            endTime: 11.8,
            text: "Keep talking — I can follow along right here.",
            isFinal: false
        ),
    ]
#endif

    private func routeDidChange(_ route: AudioRouteSnapshot) async {
        guard isSessionActive else {
            previousInputKind = route.inputKind
            return
        }

        if audioCapture.captureProfile.requiresAirPods, route.inputKind != .bluetooth {
            // Bluetooth routes can briefly report the built-in mic while iOS changes microphone
            // modes. Only stop a live session if the loss remains stable; mic preview is allowed
            // to recover on its own and never presents a disconnect alert.
            try? await Task.sleep(for: .milliseconds(750))
            guard isSessionActive,
                  audioCapture.routeSnapshot.inputKind != .bluetooth
            else { return }
            await stopCaptions()
            errorMessage = "AirPods disconnected or stopped being the active microphone, so captions were stopped."
            previousInputKind = route.inputKind
            return
        }

        if route.inputKind != previousInputKind {
            switch route.inputKind {
            case .usb:
                routeBanner = "USB microphone connected"
            case .bluetooth:
                routeBanner = "Using \(route.inputName) · \(route.activeBluetoothTuningDescription)"
            case .builtIn:
                routeBanner = "USB microphone disconnected — using iPhone microphone"
            case .other:
                routeBanner = "Using \(route.inputName)"
            case .unavailable:
                routeBanner = "No microphone available"
            }
            UINotificationFeedbackGenerator().notificationOccurred(
                route.isConnected ? .warning : .error
            )
        }
        previousInputKind = route.inputKind

        if let session = currentSession, let activeRepository {
            try? await activeRepository.updateRoute(
                sessionID: session.id,
                inputName: route.inputName,
                channelCount: route.channelCount
            )
        }
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
