import AVFAudio
import CoreMedia
import Foundation

enum SessionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case saved
    case ghost

    var id: Self { self }

    var title: String {
        switch self {
        case .saved: "Saved"
        case .ghost: "Ghost Mode"
        }
    }

}

enum InputKind: String, Codable, Sendable {
    case builtIn
    case usb
    case other
    case unavailable
}

struct AudioRouteSnapshot: Equatable, Sendable {
    var inputName: String
    var inputKind: InputKind
    var channelNames: [String]
    var channelCount: Int
    var sampleRate: Double
    var inputLatency: TimeInterval
    var ioBufferDuration: TimeInterval
    var isConnected: Bool

    static let unavailable = AudioRouteSnapshot(
        inputName: "No microphone",
        inputKind: .unavailable,
        channelNames: [],
        channelCount: 0,
        sampleRate: 0,
        inputLatency: 0,
        ioBufferDuration: 0,
        isConnected: false
    )

    var statusDescription: String {
        guard isConnected else { return "No microphone available" }
        guard channelCount > 0 else { return "Ready · format shown while captioning" }
        let format = sampleRate > 0 ? " · \(Int(sampleRate / 1_000)) kHz" : ""
        return "\(channelCount) \(channelCount == 1 ? "channel" : "channels")\(format)"
    }
}

struct AudioChannel: Identifiable, Codable, Equatable, Sendable {
    enum Accent: String, Codable, CaseIterable, Sendable {
        case neutral
        case blue
        case orange
    }

    let id: UUID
    var physicalIndex: Int
    var label: String
    var accent: Accent

    static let group = AudioChannel(
        id: UUID(uuidString: "9AF9FC90-315D-4CB7-B96F-7A53A97284F4")!,
        physicalIndex: 0,
        label: "Conversation",
        accent: .neutral
    )

}

/// `AVAudioPCMBuffer` isn't declared Sendable, but each frame owns a deep copy and is immutable
/// after capture. The capture service is the only writer.
struct TimedAudioFrame: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let startTime: CMTime
}

struct AudioMeterSnapshot: Equatable, Sendable {
    var rms: [Float]
    var peak: [Float]
    var clippedChannels: Set<Int>
    var channelsAreNearlyIdentical: Bool

    static let silent = AudioMeterSnapshot(
        rms: [],
        peak: [],
        clippedChannels: [],
        channelsAreNearlyIdentical: false
    )

    var strongestLevel: Float { rms.max() ?? 0 }
}

struct CaptionUpdate: Equatable, Sendable {
    let channel: AudioChannel
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let isFinal: Bool
    let confidence: Double?
}

struct CaptionSegment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let channel: AudioChannel
    let startTime: TimeInterval
    let endTime: TimeInterval
    var text: String
    let isFinal: Bool

    init(
        id: UUID = UUID(),
        channel: AudioChannel,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        isFinal: Bool
    ) {
        self.id = id
        self.channel = channel
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.isFinal = isFinal
    }
}

struct CaptionSession: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    let localeIdentifier: String
    let mode: SessionMode
    var inputName: String
    var channelCount: Int
    var openingExcerpt: String

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        localeIdentifier: String = "en-US",
        mode: SessionMode,
        inputName: String = "Preparing microphone",
        channelCount: Int = 0,
        openingExcerpt: String = ""
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.localeIdentifier = localeIdentifier
        self.mode = mode
        self.inputName = inputName
        self.channelCount = channelCount
        self.openingExcerpt = openingExcerpt
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

struct SessionTranscript: Equatable, Sendable {
    var session: CaptionSession
    var segments: [CaptionSegment]

    var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }

    var shareText: String {
        segments.map { segment in
            segment.channel.id == AudioChannel.group.id
                ? segment.text
                : "\(segment.channel.label): \(segment.text)"
        }
        .joined(separator: "\n\n")
    }
}

enum ModelReadiness: Equatable, Sendable {
    case checking
    case unavailable(String)
    case needsDownload
    case downloading
    case ready

    var title: String {
        switch self {
        case .checking: "Checking caption support…"
        case .unavailable(let reason): reason
        case .needsDownload: "Speech model required"
        case .downloading: "Preparing captions…"
        case .ready: "Ready"
        }
    }
}

enum VoicesInViewError: LocalizedError, Equatable {
    case microphoneDenied
    case microphoneUnavailable
    case speechUnavailable
    case unsupportedLocale
    case modelInstallationFailed(String)
    case audioConfigurationFailed(String)
    case transcriptionFailed(String)
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is off. Enable it in Settings to start captions."
        case .microphoneUnavailable:
            "No microphone input is available."
        case .speechUnavailable:
            "Apple's on-device speech model isn't available on this iPhone."
        case .unsupportedLocale:
            "US English isn't supported by the on-device speech model."
        case .modelInstallationFailed(let detail):
            "The English speech model couldn't be prepared. \(detail)"
        case .audioConfigurationFailed(let detail):
            "The microphone couldn't be started. \(detail)"
        case .transcriptionFailed(let detail):
            "Live captions stopped. \(detail)"
        case .persistenceFailed(let detail):
            "The transcript couldn't be saved. \(detail)"
        }
    }
}
