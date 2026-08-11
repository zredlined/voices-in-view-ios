import XCTest
@testable import VoicesInView

final class CaptionTimelineReducerTests: XCTestCase {
    func testVolatileResultIsReplacedInsteadOfDuplicated() {
        var reducer = CaptionTimelineReducer()

        _ = reducer.apply(update(text: "Hello", isFinal: false, start: 0, end: 0.4))
        _ = reducer.apply(update(text: "Hello there", isFinal: false, start: 0, end: 0.8))

        XCTAssertEqual(reducer.visibleSegments.count, 1)
        XCTAssertEqual(reducer.visibleSegments.first?.text, "Hello there")
        XCTAssertFalse(reducer.visibleSegments.first?.isFinal ?? true)
    }

    func testFinalResultRemovesVolatileAndIsReturnedForPersistence() {
        var reducer = CaptionTimelineReducer()
        _ = reducer.apply(update(text: "Good morn", isFinal: false, start: 0, end: 0.5))

        let finalized = reducer.apply(
            update(text: "Good morning.", isFinal: true, start: 0, end: 1)
        )

        XCTAssertEqual(finalized?.text, "Good morning.")
        XCTAssertEqual(reducer.visibleSegments, [finalized].compactMap { $0 })
        XCTAssertTrue(reducer.volatileByChannel.isEmpty)
    }

    func testDuplicateFinalResultIsIgnored() {
        var reducer = CaptionTimelineReducer()
        let result = update(text: "One sentence.", isFinal: true, start: 2, end: 3)

        XCTAssertNotNil(reducer.apply(result))
        XCTAssertNil(reducer.apply(result))
        XCTAssertEqual(reducer.finalized.count, 1)
    }

    private func update(
        text: String,
        isFinal: Bool,
        start: TimeInterval,
        end: TimeInterval
    ) -> CaptionUpdate {
        CaptionUpdate(
            channel: .group,
            startTime: start,
            endTime: end,
            text: text,
            isFinal: isFinal,
            confidence: nil
        )
    }
}
