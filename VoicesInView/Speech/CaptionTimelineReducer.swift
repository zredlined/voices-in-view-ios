import Foundation

struct CaptionTimelineReducer: Sendable {
    private(set) var finalized: [CaptionSegment] = []
    private(set) var volatileByChannel: [UUID: CaptionSegment] = [:]

    var visibleSegments: [CaptionSegment] {
        (finalized + volatileByChannel.values).sorted(by: Self.sortSegments)
    }

    mutating func apply(_ update: CaptionUpdate) -> CaptionSegment? {
        let cleaned = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if update.isFinal {
            volatileByChannel.removeValue(forKey: update.channel.id)

            if finalized.contains(where: {
                $0.channel.id == update.channel.id
                    && abs($0.startTime - update.startTime) < 0.001
                    && $0.text == cleaned
            }) {
                return nil
            }

            let segment = CaptionSegment(
                channel: update.channel,
                startTime: update.startTime,
                endTime: update.endTime,
                text: cleaned,
                isFinal: true
            )
            finalized.append(segment)
            finalized.sort(by: Self.sortSegments)
            return segment
        }

        let existingID = volatileByChannel[update.channel.id]?.id ?? UUID()
        volatileByChannel[update.channel.id] = CaptionSegment(
            id: existingID,
            channel: update.channel,
            startTime: update.startTime,
            endTime: update.endTime,
            text: cleaned,
            isFinal: false
        )
        return nil
    }

    mutating func reset() {
        finalized.removeAll(keepingCapacity: false)
        volatileByChannel.removeAll(keepingCapacity: false)
    }

    private static func sortSegments(_ lhs: CaptionSegment, _ rhs: CaptionSegment) -> Bool {
        if lhs.startTime == rhs.startTime {
            return lhs.channel.physicalIndex < rhs.channel.physicalIndex
        }
        return lhs.startTime < rhs.startTime
    }
}
