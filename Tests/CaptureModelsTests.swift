import XCTest
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

    private func makeFrame(width: Int, height: Int, index: Int) -> CapturedFrame {
        CapturedFrame(
            metadata: FrameMetadata(
                id: UUID(),
                side: .one,
                sequenceIndex: index,
                shutterIntentUptime: 1,
                callbackUptime: 2,
                capturedAt: Date(timeIntervalSince1970: 0),
                pixelWidth: width,
                pixelHeight: height,
                lens: .wide,
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
