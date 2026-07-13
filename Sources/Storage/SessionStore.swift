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
    private let fileManager = FileManager.default
    private let sessionTTL: TimeInterval = 2 * 60 * 60

    func persist(
        pair: CapturedPair,
        configuration: CaptureConfigurationSnapshot?,
        captureEvents: [CaptureEvent],
        motionSamples: [MotionSnapshot]
    ) throws -> PersistedSession {
        let root = try sessionsRoot()
        let directory = root.appendingPathComponent(pair.sessionID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup(directory)

        var shareItems: [URL] = []
        for frame in pair.sideOneFrames + pair.sideTwoFrames {
            let name = "side-\(frame.metadata.side.rawValue)-frame-\(String(format: "%02d", frame.metadata.sequenceIndex + 1)).heic"
            let url = directory.appendingPathComponent(name)
            try frame.imageData.write(to: url, options: [.atomic, .completeFileProtection])
            try excludeFromBackup(url)
            shareItems.append(url)
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
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: manifestURL, options: [.atomic, .completeFileProtection])
        try excludeFromBackup(manifestURL)
        shareItems.append(manifestURL)

        return PersistedSession(id: pair.sessionID, directory: directory, shareItems: shareItems)
    }

    func delete(_ session: PersistedSession?) {
        guard let session else { return }
        try? fileManager.removeItem(at: session.directory)
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
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent("groupCam/Sessions", isDirectory: true)
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
