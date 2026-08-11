import AVFAudio
import XCTest
@testable import VoicesInView

final class AudioMixerTests: XCTestCase {
    func testInactiveInputDoesNotClaimToHaveZeroChannels() {
        let snapshot = AudioRouteSnapshot(
            inputName: "iPhone Microphone",
            inputKind: .builtIn,
            channelNames: [],
            channelCount: 0,
            sampleRate: 0,
            inputLatency: 0,
            ioBufferDuration: 0,
            isConnected: true
        )

        XCTAssertEqual(snapshot.statusDescription, "Ready · format shown while captioning")
    }

    func testActiveInputDescribesItsNegotiatedFormat() {
        let snapshot = AudioRouteSnapshot(
            inputName: "iPhone Microphone",
            inputKind: .builtIn,
            channelNames: ["Channel 1"],
            channelCount: 1,
            sampleRate: 48_000,
            inputLatency: 0.01,
            ioBufferDuration: 0.02,
            isConnected: true
        )

        XCTAssertEqual(snapshot.statusDescription, "1 channel · 48 kHz")
    }

    @MainActor
    func testStoppingAudioCaptureIsSafeBeforeStarting() {
        let capture = AudioCaptureService()

        capture.stop()
        capture.stop()
    }

    func testStereoChannelsAreMixedWithHeadroom() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        input.frameLength = 4
        let channels = try XCTUnwrap(input.floatChannelData)

        for frame in 0 ..< 4 {
            channels[0][frame] = 0.5
            channels[1][frame] = 0.5
        }

        let output = try XCTUnwrap(AudioMixer.downmixToMono(input))
        let samples = try XCTUnwrap(output.floatChannelData?[0])

        XCTAssertEqual(output.format.channelCount, 1)
        XCTAssertEqual(output.frameLength, 4)
        XCTAssertEqual(samples[0], 0.45, accuracy: 0.0001)
    }

    func testMeterReportsEachChannelAndClipping() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        input.frameLength = 2
        let channels = try XCTUnwrap(input.floatChannelData)
        channels[0][0] = 1
        channels[0][1] = 0.5
        channels[1][0] = 0.01
        channels[1][1] = 0.01

        let meter = AudioMixer.meterSnapshot(for: input)

        XCTAssertEqual(meter.rms.count, 2)
        XCTAssertGreaterThan(meter.rms[0], meter.rms[1])
        XCTAssertTrue(meter.clippedChannels.contains(0))
        XCTAssertFalse(meter.clippedChannels.contains(1))
        XCTAssertFalse(meter.channelsAreNearlyIdentical)
    }

    func testMeterDetectsDuplicatedStereoChannels() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        input.frameLength = 64
        let channels = try XCTUnwrap(input.floatChannelData)

        for frame in 0 ..< 64 {
            let sample = Float(frame % 8) / 8
            channels[0][frame] = sample
            channels[1][frame] = sample
        }

        XCTAssertTrue(AudioMixer.meterSnapshot(for: input).channelsAreNearlyIdentical)
    }

    func testConvertedLiveAudioUsesContiguousAnalyzerTiming() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        buffer.frameLength = 320

        let input = LiveAnalyzerInputFactory.contiguous(buffer: buffer)

        XCTAssertNil(input.bufferStartTime)
    }
}
