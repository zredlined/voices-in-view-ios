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
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var firstCaptionLatency: TimeInterval?
    @Published private(set) var history: [CaptionSession] = []
    @Published var errorMessage: String?
    @Published var routeBanner: String?

    let audioCapture: AudioCaptureService

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
    private var micTestTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var firstSpeechDetectedAt: ContinuousClock.Instant?
    private var previousInputKind: InputKind = .unavailable

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
    }

    func refreshModelReadiness() async {
        modelReadiness = .checking
        modelReadiness = await transcriptionEngine.readiness(for: locale)
    }

    func refreshHistory() async {
        do {
            history = try await savedRepository.list()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startCaptions() async {
        guard !isSessionActive, !isStarting else { return }
        if isTestingMicrophones {
            stopMicrophoneTest()
        }
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

            let frames = try await audioCapture.start()
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
            audioCapture.stop()
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
        if isTestingMicrophones {
            stopMicrophoneTest()
            return
        }

        errorMessage = nil
        do {
            let frames = try await audioCapture.start()
            isTestingMicrophones = true
            micTestTask = Task {
                for await _ in frames {
                    if Task.isCancelled { return }
                }
            }
        } catch {
            audioCapture.stop()
            isTestingMicrophones = false
            errorMessage = error.localizedDescription
        }
    }

    func stopMicrophoneTest() {
        audioCapture.stop()
        micTestTask?.cancel()
        micTestTask = nil
        isTestingMicrophones = false
    }

    func stopCaptions() async {
        guard isSessionActive, !isStopping else { return }
        isStopping = true
        let session = currentSession
        let endedAt = Date()
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
        isSessionActive = false
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
        try await savedRepository.load(sessionID: session.id)
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

    private func routeDidChange(_ route: AudioRouteSnapshot) async {
        guard isSessionActive else {
            previousInputKind = route.inputKind
            return
        }

        if route.inputKind != previousInputKind {
            switch route.inputKind {
            case .usb:
                routeBanner = "USB microphone connected"
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
