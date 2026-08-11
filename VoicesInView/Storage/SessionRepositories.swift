import Foundation

actor SavedSessionRepository: SessionRepository {
    private enum FileName {
        static let metadata = "metadata.json"
        static let segments = "segments.ndjson"
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.rootURL = applicationSupport
                .appending(path: "VoicesInView", directoryHint: .isDirectory)
                .appending(path: "Sessions", directoryHint: .isDirectory)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func begin(_ session: CaptionSession) async throws {
        do {
            try prepareRootDirectory()
            let directory = sessionDirectory(session.id)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try excludeFromBackup(directory)
            try writeMetadata(session)

            let segmentsURL = directory.appending(path: FileName.segments)
            guard fileManager.createFile(
                atPath: segmentsURL.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            throw VoicesInViewError.persistenceFailed(error.localizedDescription)
        }
    }

    func updateRoute(sessionID: UUID, inputName: String, channelCount: Int) async throws {
        do {
            var session = try readMetadata(sessionID)
            session.inputName = inputName
            session.channelCount = channelCount
            try writeMetadata(session)
        } catch {
            throw VoicesInViewError.persistenceFailed(error.localizedDescription)
        }
    }

    func append(_ segment: CaptionSegment, to sessionID: UUID) async throws {
        guard segment.isFinal else { return }

        do {
            let fileURL = sessionDirectory(sessionID).appending(path: FileName.segments)
            var line = try encoder.encode(segment)
            line.append(0x0A)

            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            try handle.close()

            var session = try readMetadata(sessionID)
            if session.openingExcerpt.isEmpty {
                session.openingExcerpt = String(segment.text.prefix(120))
                try writeMetadata(session)
            }
        } catch {
            throw VoicesInViewError.persistenceFailed(error.localizedDescription)
        }
    }

    func finish(sessionID: UUID, endedAt: Date) async throws {
        do {
            var session = try readMetadata(sessionID)
            session.endedAt = endedAt
            try writeMetadata(session)
        } catch {
            throw VoicesInViewError.persistenceFailed(error.localizedDescription)
        }
    }

    func list() async throws -> [CaptionSession] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }

        do {
            let directories = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            return directories
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .compactMap { directory in
                    let metadataURL = directory.appending(path: FileName.metadata)
                    guard let data = try? Data(contentsOf: metadataURL) else { return nil }
                    return try? decoder.decode(CaptionSession.self, from: data)
                }
                .sorted { $0.startedAt > $1.startedAt }
        } catch {
            throw VoicesInViewError.persistenceFailed(error.localizedDescription)
        }
    }

    func load(sessionID: UUID) async throws -> SessionTranscript {
        do {
            let session = try readMetadata(sessionID)
            let segmentsURL = sessionDirectory(sessionID).appending(path: FileName.segments)
            let data = try Data(contentsOf: segmentsURL)
            let segments = data
                .split(separator: 0x0A, omittingEmptySubsequences: true)
                .compactMap { try? decoder.decode(CaptionSegment.self, from: Data($0)) }
                .sorted { lhs, rhs in
                    if lhs.startTime == rhs.startTime {
                        lhs.channel.physicalIndex < rhs.channel.physicalIndex
                    } else {
                        lhs.startTime < rhs.startTime
                    }
                }
            return SessionTranscript(session: session, segments: segments)
        } catch {
            throw VoicesInViewError.persistenceFailed(error.localizedDescription)
        }
    }

    func delete(sessionID: UUID) async throws {
        do {
            let directory = sessionDirectory(sessionID)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        } catch {
            throw VoicesInViewError.persistenceFailed(error.localizedDescription)
        }
    }

    private func prepareRootDirectory() throws {
        if !fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        try excludeFromBackup(rootURL)
    }

    private func sessionDirectory(_ id: UUID) -> URL {
        rootURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func metadataURL(_ id: UUID) -> URL {
        sessionDirectory(id).appending(path: FileName.metadata)
    }

    private func writeMetadata(_ session: CaptionSession) throws {
        let data = try encoder.encode(session)
        try data.write(
            to: metadataURL(session.id),
            options: [.atomic, .completeFileProtection]
        )
    }

    private func readMetadata(_ id: UUID) throws -> CaptionSession {
        let data = try Data(contentsOf: metadataURL(id))
        return try decoder.decode(CaptionSession.self, from: data)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

actor EphemeralSessionRepository: SessionRepository {
    private var transcripts: [UUID: SessionTranscript] = [:]

    func begin(_ session: CaptionSession) async throws {
        transcripts[session.id] = SessionTranscript(session: session, segments: [])
    }

    func updateRoute(sessionID: UUID, inputName: String, channelCount: Int) async throws {
        guard var transcript = transcripts[sessionID] else { return }
        transcript.session.inputName = inputName
        transcript.session.channelCount = channelCount
        transcripts[sessionID] = transcript
    }

    func append(_ segment: CaptionSegment, to sessionID: UUID) async throws {
        guard segment.isFinal, var transcript = transcripts[sessionID] else { return }
        transcript.segments.append(segment)
        if transcript.session.openingExcerpt.isEmpty {
            transcript.session.openingExcerpt = String(segment.text.prefix(120))
        }
        transcripts[sessionID] = transcript
    }

    func finish(sessionID: UUID, endedAt: Date) async throws {
        guard var transcript = transcripts[sessionID] else { return }
        transcript.session.endedAt = endedAt
        transcripts[sessionID] = transcript
    }

    func list() async throws -> [CaptionSession] {
        transcripts.values.map(\.session).sorted { $0.startedAt > $1.startedAt }
    }

    func load(sessionID: UUID) async throws -> SessionTranscript {
        guard let transcript = transcripts[sessionID] else {
            throw VoicesInViewError.persistenceFailed("The private session has ended.")
        }
        return transcript
    }

    func delete(sessionID: UUID) async throws {
        transcripts[sessionID] = nil
    }

    func removeAll() {
        transcripts.removeAll(keepingCapacity: false)
    }
}
