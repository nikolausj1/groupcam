import XCTest
import simd
@testable import groupCam

final class CaptureModelsTests: XCTestCase {
    func testCRC32MatchesStandardVector() {
        XCTAssertEqual(CRC32.checksum(data: Data("123456789".utf8)), 0xCBF43926)
    }

    func testCorpusArchiveContainsBothEntriesAndCentralDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.heic")
        let second = root.appendingPathComponent("manifest.json")
        try Data("image-data".utf8).write(to: first)
        try Data("{\"ok\":true}".utf8).write(to: second)
        let archive = root.appendingPathComponent("session.zip")
        try ZipArchiveWriter().write(files: [first, second], to: archive)

        let data = try Data(contentsOf: archive)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertTrue(data.range(of: Data("first.heic".utf8)) != nil)
        XCTAssertTrue(data.range(of: Data("manifest.json".utf8)) != nil)
        XCTAssertTrue(data.range(of: Data([0x50, 0x4B, 0x05, 0x06])) != nil)
    }

    func testAutoSequenceUsesThreeFrames() {
        XCTAssertEqual(SequenceLength.auto.rawValue, 3)
    }

    func testProvisionalFramePrefersLargestSource() {
        let smaller = makeFrame(width: 1_000, height: 1_000, index: 0)
        let larger = makeFrame(width: 4_000, height: 3_000, index: 1)
        let pair = CapturedPair(
            sessionID: UUID(),
            sideOneFrames: [smaller, larger],
            sideTwoFrames: []
        )

        XCTAssertEqual(pair.provisionalSideOne?.id, larger.id)
    }

    func testRepersistingSessionRemovesStaleRetakeFrames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SessionStore(rootDirectory: root)
        var pair = CapturedPair(
            sessionID: UUID(),
            sideOneFrames: [makeFrame(width: 10, height: 10, index: 0)],
            sideTwoFrames: (0..<5).map {
                makeFrame(width: 10, height: 10, index: $0, side: .two)
            }
        )
        var session: PersistedSession?
        defer { try? FileManager.default.removeItem(at: root) }

        session = try store.persist(
            pair: pair,
            configuration: nil,
            captureEvents: [],
            motionSamples: []
        )
        pair.sideTwoFrames = Array(pair.sideTwoFrames.prefix(3))
        session = try store.persist(
            pair: pair,
            configuration: nil,
            captureEvents: [],
            motionSamples: []
        )

        let files = try FileManager.default.contentsOfDirectory(
            at: try XCTUnwrap(session?.directory),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertFalse(files.contains("side-two-frame-04.heic"))
        XCTAssertFalse(files.contains("side-two-frame-05.heic"))
    }

    func testPersistFailurePreservesPreviousSessionAndCleansStagingDirectory() throws {
        enum ExpectedFailure: Error {
            case injected
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID()
        let originalPair = CapturedPair(
            sessionID: sessionID,
            sideOneFrames: [makeFrame(width: 10, height: 10, index: 0)],
            sideTwoFrames: (0..<5).map {
                makeFrame(width: 10, height: 10, index: $0, side: .two)
            }
        )
        let store = SessionStore(rootDirectory: root)
        let originalSession = try store.persist(
            pair: originalPair,
            configuration: nil,
            captureEvents: [],
            motionSamples: []
        )
        let originalFiles = try FileManager.default.contentsOfDirectory(
            at: originalSession.directory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()

        let failingStore = SessionStore(rootDirectory: root) { _, url, _ in
            if url.lastPathComponent == "side-two-frame-02.heic" {
                throw ExpectedFailure.injected
            }
            try Data("staged".utf8).write(to: url, options: .atomic)
        }
        let retakePair = CapturedPair(
            sessionID: sessionID,
            sideOneFrames: originalPair.sideOneFrames,
            sideTwoFrames: Array(originalPair.sideTwoFrames.prefix(3))
        )

        XCTAssertThrowsError(
            try failingStore.persist(
                pair: retakePair,
                configuration: nil,
                captureEvents: [],
                motionSamples: []
            )
        ) { error in
            XCTAssertTrue(error is ExpectedFailure)
        }

        let filesAfterFailure = try FileManager.default.contentsOfDirectory(
            at: originalSession.directory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        XCTAssertEqual(filesAfterFailure, originalFiles)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent),
            [sessionID.uuidString]
        )
    }

    func testCameraPreviewRotationMatchesInterfaceOrientation() {
        XCTAssertEqual(CameraInterfaceRotation.angle(for: .portrait), 90)
        XCTAssertEqual(CameraInterfaceRotation.angle(for: .landscapeRight), 0)
        XCTAssertEqual(CameraInterfaceRotation.angle(for: .landscapeLeft), 180)
        XCTAssertEqual(CameraInterfaceRotation.angle(for: .portraitUpsideDown), 270)
        XCTAssertTrue(CameraInterfaceRotation.matches(expectedAngle: 0, orientation: .landscapeRight))
        XCTAssertTrue(CameraInterfaceRotation.matches(expectedAngle: 180, orientation: .landscapeLeft))
        XCTAssertFalse(CameraInterfaceRotation.matches(expectedAngle: 0, orientation: .landscapeLeft))
        XCTAssertFalse(CameraInterfaceRotation.matches(expectedAngle: 90, orientation: .unknown))
    }

    func testHomographyPlausibilityAcceptsNormalHandoffTransform() {
        let matrix = simd_float3x3(columns: (
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(40, -50, 1)
        ))
        XCTAssertTrue(
            GroupPhotoCompositor.alignmentIsPlausible(
                matrix: matrix,
                extent: CGRect(x: 0, y: 0, width: 2_016, height: 1_512)
            )
        )
    }

    func testHomographyPlausibilityRejectsDegenerateTransform() {
        let matrix = simd_float3x3(columns: (
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(100_000, 100_000, 0.001)
        ))
        XCTAssertFalse(
            GroupPhotoCompositor.alignmentIsPlausible(
                matrix: matrix,
                extent: CGRect(x: 0, y: 0, width: 2_016, height: 1_512)
            )
        )
    }

    func testCaptureSnapshotDecodesLegacyPayloadWithoutZoom() throws {
        let json = """
        {
          "lens": "wide",
          "rotationAngleDegrees": 90,
          "requestedMaxPhotoWidth": 4032,
          "requestedMaxPhotoHeight": 3024,
          "lensPosition": 0.5,
          "exposureDurationSeconds": 0.0083333333,
          "iso": 50,
          "whiteBalanceRedGain": 1,
          "whiteBalanceGreenGain": 1,
          "whiteBalanceBlueGain": 1
        }
        """

        let snapshot = try JSONDecoder().decode(
            CaptureConfigurationSnapshot.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(snapshot.videoZoomFactor)
    }

    @MainActor
    func testZoomIsFrozenAfterPhotoOneConfigurationLocks() async throws {
        let camera = CameraRecorder()
        try await camera.requestAccessAndConfigure(lens: .wide)
        camera.setZoomFactor(1.6)

        _ = try await withCheckedThrowingContinuation { continuation in
            camera.captureSequence(
                side: .one,
                count: 1,
                interfaceRotationAngleDegrees: 90
            ) { result in
                continuation.resume(with: result)
            }
        }

        XCTAssertEqual(
            camera.pairConfiguration?.videoZoomFactor ?? -1,
            1.6,
            accuracy: 0.001
        )
        XCTAssertEqual(camera.pairConfiguration?.rotationAngleDegrees, 90)
        camera.setZoomFactor(1)
        XCTAssertEqual(camera.zoomFactor, 1.6, accuracy: 0.001)
    }

    private func makeFrame(
        width: Int,
        height: Int,
        index: Int,
        side: CaptureSide = .one
    ) -> CapturedFrame {
        CapturedFrame(
            metadata: FrameMetadata(
                id: UUID(),
                side: side,
                sequenceIndex: index,
                shutterIntentUptime: 1,
                callbackUptime: 2,
                capturedAt: Date(timeIntervalSince1970: 0),
                pixelWidth: width,
                pixelHeight: height,
                lens: .wide,
                videoZoomFactor: nil,
                motion: nil,
                exposureDurationSeconds: nil,
                iso: nil,
                whiteBalanceRedGain: nil,
                whiteBalanceGreenGain: nil,
                whiteBalanceBlueGain: nil,
                lensPosition: nil,
                captureMetadataPropertyList: nil
            ),
            imageData: Data()
        )
    }
}
