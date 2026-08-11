import AVFAudio
import Foundation

enum AudioMixer {
    static func downmixToMono(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.frameLength > 0,
              let source = input.floatChannelData,
              let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: input.format.sampleRate,
                channels: 1,
                interleaved: false
              ),
              let output = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: input.frameLength
              ),
              let destination = output.floatChannelData?[0]
        else {
            return nil
        }

        output.frameLength = input.frameLength
        let channelCount = max(1, Int(input.format.channelCount))
        let scale = 0.9 / Float(channelCount)

        for frame in 0 ..< Int(input.frameLength) {
            var mixed: Float = 0
            for channel in 0 ..< channelCount {
                mixed += source[channel][frame]
            }
            destination[frame] = max(-1, min(1, mixed * scale))
        }

        return output
    }

    static func meterSnapshot(for input: AVAudioPCMBuffer) -> AudioMeterSnapshot {
        guard input.frameLength > 0, let channels = input.floatChannelData else {
            return .silent
        }

        var rmsValues: [Float] = []
        var peaks: [Float] = []
        var clipped: Set<Int> = []
        let channelCount = Int(input.format.channelCount)

        for channel in 0 ..< channelCount {
            var sumSquares: Float = 0
            var peak: Float = 0

            for frame in 0 ..< Int(input.frameLength) {
                let sample = abs(channels[channel][frame])
                sumSquares += sample * sample
                peak = max(peak, sample)
            }

            let rawRMS = sqrt(sumSquares / Float(input.frameLength))
            let decibels = rawRMS > 0 ? 20 * log10(rawRMS) : -60
            let visibleLevel = max(0, min(1, (decibels + 60) / 60))
            rmsValues.append(visibleLevel)
            peaks.append(peak)

            if peak >= 0.98 {
                clipped.insert(channel)
            }
        }

        var channelsAreNearlyIdentical = false
        if channelCount >= 2 {
            var signalEnergy: Float = 0
            var differenceEnergy: Float = 0

            for frame in 0 ..< Int(input.frameLength) {
                let left = channels[0][frame]
                let right = channels[1][frame]
                signalEnergy += left * left + right * right
                let difference = left - right
                differenceEnergy += difference * difference
            }

            let meanSignalEnergy = signalEnergy / Float(input.frameLength * 2)
            let normalizedDifference = differenceEnergy / max(signalEnergy, 0.000_001)
            channelsAreNearlyIdentical = meanSignalEnergy > 0.000_01
                && normalizedDifference < 0.000_1
        }

        return AudioMeterSnapshot(
            rms: rmsValues,
            peak: peaks,
            clippedChannels: clipped,
            channelsAreNearlyIdentical: channelsAreNearlyIdentical
        )
    }
}

final class AudioFrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: AVAudioFramePosition?

    func relativeTime(sampleTime: AVAudioFramePosition, sampleRate: Double) -> CMTime {
        lock.lock()
        defer { lock.unlock() }

        let first = origin ?? sampleTime
        origin = first
        let relative = max(0, sampleTime - first)
        let timeScale = CMTimeScale(max(1, Int32(sampleRate.rounded())))
        return CMTime(value: relative, timescale: timeScale)
    }

    func reset() {
        lock.lock()
        origin = nil
        lock.unlock()
    }
}
