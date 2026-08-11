import Foundation

@MainActor
protocol AudioCapturing: AnyObject {
    var routeSnapshot: AudioRouteSnapshot { get }
    var meterSnapshot: AudioMeterSnapshot { get }
    var droppedFrameCount: Int { get }
    var lastRouteEvent: String { get }

    func requestPermission() async -> Bool
    func refreshRoute()
    func start() async throws -> AsyncStream<TimedAudioFrame>
    func stop()
}

protocol LiveTranscriptionEngine: Sendable {
    func readiness(for locale: Locale) async -> ModelReadiness
    func prepare(locale: Locale) async throws
    func start(
        frames: AsyncStream<TimedAudioFrame>,
        channel: AudioChannel,
        locale: Locale
    ) async throws -> AsyncThrowingStream<CaptionUpdate, Error>
    func finish() async
    func cancel() async
}

protocol SessionRepository: Sendable {
    func begin(_ session: CaptionSession) async throws
    func updateRoute(sessionID: UUID, inputName: String, channelCount: Int) async throws
    func append(_ segment: CaptionSegment, to sessionID: UUID) async throws
    func finish(sessionID: UUID, endedAt: Date) async throws
    func list() async throws -> [CaptionSession]
    func load(sessionID: UUID) async throws -> SessionTranscript
    func delete(sessionID: UUID) async throws
}
