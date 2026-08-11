@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech

actor AppleSpeechEngine: LiveTranscriptionEngine {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var captionContinuation: AsyncThrowingStream<CaptionUpdate, Error>.Continuation?
    private var frameTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var converter: StreamingAudioConverter?

    func readiness(for locale: Locale) async -> ModelReadiness {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable("On-device transcription isn't available on this iPhone")
        }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unavailable("US English isn't supported on this iPhone")
        }

        let probe = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [probe]) {
        case .installed:
            return .ready
        case .downloading:
            return .downloading
        case .supported:
            return .needsDownload
        case .unsupported:
            return .unavailable("The English speech model isn't supported on this iPhone")
        @unknown default:
            return .checking
        }
    }

    func prepare(locale: Locale) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw VoicesInViewError.speechUnavailable
        }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoicesInViewError.unsupportedLocale
        }

        let module = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw VoicesInViewError.modelInstallationFailed(error.localizedDescription)
        }

        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw VoicesInViewError.modelInstallationFailed("The model did not finish installing.")
        }
    }

    func start(
        frames: AsyncStream<TimedAudioFrame>,
        channel: AudioChannel,
        locale: Locale
    ) async throws -> AsyncThrowingStream<CaptionUpdate, Error> {
        await cancel()

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoicesInViewError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw VoicesInViewError.transcriptionFailed("No compatible on-device audio format was found.")
        }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let analyzerInputPair = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(24)
        )
        let captionPair = AsyncThrowingStream.makeStream(
            of: CaptionUpdate.self,
            bufferingPolicy: .bufferingNewest(64)
        )

        self.analyzer = analyzer
        self.transcriber = transcriber
        analyzerInputContinuation = analyzerInputPair.continuation
        captionContinuation = captionPair.continuation
        converter = StreamingAudioConverter(targetFormat: analyzerFormat)

        frameTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeFrames(frames, into: analyzerInputPair.continuation)
        }

        analysisTask = Task { [weak self] in
            do {
                _ = try await analyzer.analyzeSequence(analyzerInputPair.stream)
            } catch is CancellationError {
                return
            } catch {
                await self?.finishCaptions(throwing: error)
            }
        }

        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let start = result.range.start.seconds
                    let end = result.range.end.seconds
                    captionPair.continuation.yield(
                        CaptionUpdate(
                            channel: channel,
                            startTime: start.isFinite ? start : 0,
                            endTime: end.isFinite ? end : 0,
                            text: text,
                            isFinal: result.isFinal,
                            confidence: nil
                        )
                    )
                }
                captionPair.continuation.finish()
            } catch is CancellationError {
                captionPair.continuation.finish()
            } catch {
                await self?.finishCaptions(throwing: error)
            }
        }

        return captionPair.stream
    }

    func finish() async {
        await frameTask?.value
        analyzerInputContinuation?.finish()

        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                finishCaptions(throwing: error)
            }
        }

        await analysisTask?.value
        await resultTask?.value
        captionContinuation?.finish()
        clearState()
    }

    func cancel() async {
        frameTask?.cancel()
        analyzerInputContinuation?.finish()
        analysisTask?.cancel()
        resultTask?.cancel()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        captionContinuation?.finish()
        clearState()
    }

    private func consumeFrames(
        _ frames: AsyncStream<TimedAudioFrame>,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) async {
        do {
            for await frame in frames {
                try Task.checkCancellation()
                guard let converted = try converter?.convert(frame.buffer) else { continue }
                continuation.yield(LiveAnalyzerInputFactory.contiguous(buffer: converted))
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish()
            finishCaptions(throwing: error)
        }
    }

    private func finishCaptions(throwing error: Error) {
        captionContinuation?.finish(
            throwing: VoicesInViewError.transcriptionFailed(error.localizedDescription)
        )
    }

    private func clearState() {
        analyzer = nil
        transcriber = nil
        analyzerInputContinuation = nil
        captionContinuation = nil
        frameTask = nil
        analysisTask = nil
        resultTask = nil
        converter = nil
    }
}

/// Converted live buffers form one continuous stream. Their capture timestamps cannot be
/// reused because AVAudioConverter priming can move samples into a later output buffer.
enum LiveAnalyzerInputFactory {
    static func contiguous(buffer: AVAudioPCMBuffer) -> AnalyzerInput {
        AnalyzerInput(buffer: buffer)
    }
}

private final class StreamingAudioConverter: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        if input.format == targetFormat {
            return input
        }

        if sourceFormat != input.format {
            sourceFormat = input.format
            converter = AVAudioConverter(from: input.format, to: targetFormat)
        }

        guard let converter else {
            throw VoicesInViewError.transcriptionFailed("The microphone format couldn't be converted.")
        }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, ceil(Double(input.frameLength) * ratio) + 32))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw VoicesInViewError.transcriptionFailed("An audio conversion buffer couldn't be created.")
        }

        let inputState = ConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if inputState.providedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputState.providedInput = true
            inputStatus.pointee = .haveData
            return input
        }

        if let conversionError {
            throw conversionError
        }

        switch status {
        case .haveData, .inputRanDry:
            return output.frameLength > 0 ? output : nil
        case .endOfStream:
            return output.frameLength > 0 ? output : nil
        case .error:
            throw VoicesInViewError.transcriptionFailed("Audio conversion failed.")
        @unknown default:
            return nil
        }
    }
}

private final class ConverterInputState: @unchecked Sendable {
    var providedInput = false
}
