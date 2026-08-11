import Foundation
import XCTest
@testable import VoicesInView

final class SessionRepositoryTests: XCTestCase {
    func testSavedRepositoryPersistsFinalSegmentsAndDeletesSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = SavedSessionRepository(rootURL: root)
        let session = CaptionSession(mode: .saved)
        let volatile = segment(text: "Draft", isFinal: false)
        let final = segment(text: "Final caption.", isFinal: true)

        try await repository.begin(session)
        try await repository.append(volatile, to: session.id)
        try await repository.append(final, to: session.id)
        try await repository.finish(sessionID: session.id, endedAt: Date())

        let list = try await repository.list()
        let loaded = try await repository.load(sessionID: session.id)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.openingExcerpt, "Final caption.")
        XCTAssertEqual(loaded.segments, [final])

        try await repository.delete(sessionID: session.id)
        let remainingSessions = try await repository.list()
        XCTAssertTrue(remainingSessions.isEmpty)
    }

    func testEphemeralRepositoryNeverCreatesFiles() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repository = EphemeralSessionRepository()
        let session = CaptionSession(mode: .ghost)

        try await repository.begin(session)
        try await repository.append(segment(text: "Private words", isFinal: true), to: session.id)
        let loaded = try await repository.load(sessionID: session.id)

        XCTAssertEqual(loaded.plainText, "Private words")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        await repository.removeAll()
        let remainingSessions = try await repository.list()
        XCTAssertTrue(remainingSessions.isEmpty)
    }

    private func segment(text: String, isFinal: Bool) -> CaptionSegment {
        CaptionSegment(
            channel: .group,
            startTime: 0,
            endTime: 1,
            text: text,
            isFinal: isFinal
        )
    }
}
