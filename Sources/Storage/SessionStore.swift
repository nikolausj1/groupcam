import Foundation

struct PersistedSession {
    let id: UUID
    let directory: URL
    let shareItems: [URL]
}

private struct SessionManifest: Codable {
    let schemaVersion: Int
    let sessionID: UUID
    let createdAt: Date
    let pairConfiguration: CaptureConfigurationSnapshot?
    let captureEvents: [CaptureEvent]
    let motionSamples: [MotionSnapshot]
    let sideOneFrames: [FrameMetadata]
    let sideTwoFrames: [FrameMetadata]
}

struct SessionStore {
    private let fileManager: FileManager
    private let rootDirectoryOverride: URL?
    private let dataWriter: (Data, URL, Data.WritingOptions) throws -> Void
    private let sessionTTL: TimeInterval = 2 * 60 * 60

    init(
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil,
        dataWriter: @escaping (Data, URL, Data.WritingOptions) throws -> Void = {
            data,
            url,
            options in
            try data.write(to: url, options: options)
        }
    ) {
        self.fileManager = fileManager
        rootDirectoryOverride = rootDirectory
        self.dataWriter = dataWriter
    }

    func persist(
        pair: CapturedPair,
        configuration: CaptureConfigurationSnapshot?,
        captureEvents: [CaptureEvent],
        motionSamples: [MotionSnapshot]
    ) throws -> PersistedSession {
        let root = try sessionsRoot()
        let directory = root.appendingPathComponent(pair.sessionID.uuidString, isDirectory: true)
        let stagingDirectory = root.appendingPathComponent(
            ".\(pair.sessionID.uuidString).\(UUID().uuidString).staging",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        try excludeFromBackup(stagingDirectory)
        defer {
            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try? fileManager.removeItem(at: stagingDirectory)
            }
        }

        var shareItemNames: [String] = []
        for frame in pair.sideOneFrames + pair.sideTwoFrames {
            let name = "side-\(frame.metadata.side.rawValue)-frame-\(String(format: "%02d", frame.metadata.sequenceIndex + 1)).heic"
            let url = stagingDirectory.appendingPathComponent(name)
            try dataWriter(frame.imageData, url, [.atomic, .completeFileProtection])
            try excludeFromBackup(url)
            shareItemNames.append(name)
        }

        let manifest = SessionManifest(
            schemaVersion: 1,
            sessionID: pair.sessionID,
            createdAt: Date(),
            pairConfiguration: configuration,
            captureEvents: captureEvents,
            motionSamples: motionSamples,
            sideOneFrames: pair.sideOneFrames.map(\.metadata),
            sideTwoFrames: pair.sideTwoFrames.map(\.metadata)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let manifestName = "manifest.json"
        let manifestURL = stagingDirectory.appendingPathComponent(manifestName)
        try dataWriter(
            encoder.encode(manifest),
            manifestURL,
            [.atomic, .completeFileProtection]
        )
        try excludeFromBackup(manifestURL)
        shareItemNames.append(manifestName)

        if fileManager.fileExists(atPath: directory.path) {
            _ = try fileManager.replaceItemAt(directory, withItemAt: stagingDirectory)
        } else {
            try fileManager.moveItem(at: stagingDirectory, to: directory)
        }

        let shareItems = shareItemNames.map(directory.appendingPathComponent)

        return PersistedSession(id: pair.sessionID, directory: directory, shareItems: shareItems)
    }

    func delete(_ session: PersistedSession?) {
        guard let session else { return }
        try? fileManager.removeItem(at: session.directory)
    }

    func createCorpusArchive(for session: PersistedSession) throws -> URL {
        let archive = session.directory.appendingPathComponent(
            "groupCam-\(session.id.uuidString).zip"
        )
        try ZipArchiveWriter().write(files: session.shareItems, to: archive)
        try excludeFromBackup(archive)
        return archive
    }

    func deleteCorpusArchive(_ archive: URL?) {
        guard let archive else { return }
        try? fileManager.removeItem(at: archive)
    }

    func cleanupExpiredSessions(now: Date = Date()) {
        guard let root = try? sessionsRoot(),
              let directories = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > sessionTTL {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    private func sessionsRoot() throws -> URL {
        let root: URL
        if let rootDirectoryOverride {
            root = rootDirectoryOverride
        } else {
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            root = support.appendingPathComponent("groupCam/Sessions", isDirectory: true)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromBackup(root)
        return root
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}
