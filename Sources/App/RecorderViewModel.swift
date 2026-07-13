import Foundation
import SwiftUI

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var step: RecorderStep = .setup
    @Published var selectedLens: CaptureLens = .wide
    @Published var sequenceLength: SequenceLength = .auto
    @Published var everyoneConsented = false
    @Published var corpusExportConsented = false
    @Published var pair = CapturedPair(sessionID: UUID(), sideOneFrames: [], sideTwoFrames: [])
    @Published var persistedSession: PersistedSession?
    @Published var corpusArchiveURL: URL?
    @Published var isPreparingCamera = false
    @Published var isCapturing = false
    @Published var message: String?

    let camera = CameraRecorder()
    private let store = SessionStore()

    init() {
        store.cleanupExpiredSessions()
    }

    var onionSkinImage: UIImage? {
        pair.provisionalSideOne?.image
    }

    var canExportCorpus: Bool {
        #if DEBUG
        corpusExportConsented && persistedSession != nil
        #else
        false
        #endif
    }

    func prepareCorpusExport() -> Bool {
        guard corpusExportConsented, let persistedSession else { return false }
        store.deleteCorpusArchive(corpusArchiveURL)
        do {
            corpusArchiveURL = try store.createCorpusArchive(for: persistedSession)
            return true
        } catch {
            message = "The corpus package could not be created: \(error.localizedDescription)"
            corpusArchiveURL = nil
            return false
        }
    }

    func finishCorpusExport() {
        store.deleteCorpusArchive(corpusArchiveURL)
        corpusArchiveURL = nil
    }

    func begin() {
        guard everyoneConsented else {
            message = "Confirm that everyone agrees to be photographed before continuing."
            return
        }
        isPreparingCamera = true
        message = nil
        Task {
            do {
                try await camera.requestAccessAndConfigure(lens: selectedLens)
                step = .sideOneInstructions
            } catch {
                message = error.localizedDescription
            }
            isPreparingCamera = false
        }
    }

    func chooseLens(_ lens: CaptureLens) {
        selectedLens = lens
        do {
            try camera.switchLens(to: lens)
        } catch {
            message = error.localizedDescription
        }
    }

    func capture(side: CaptureSide) {
        guard !isCapturing else { return }
        isCapturing = true
        message = nil
        camera.captureSequence(side: side, count: sequenceLength.rawValue) { [weak self] result in
            guard let self else { return }
            isCapturing = false
            switch result {
            case .success(let frames):
                if side == .one {
                    pair.sideOneFrames = frames
                    step = .handoff
                } else {
                    pair.sideTwoFrames = frames
                    do {
                        persistedSession = try store.persist(
                            pair: pair,
                            configuration: camera.pairConfiguration,
                            captureEvents: camera.captureEvents,
                            motionSamples: camera.recordedMotionSamples
                        )
                        step = .review
                    } catch {
                        message = "The captures succeeded, but the protected session package could not be written: \(error.localizedDescription)"
                    }
                }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    func repeatSideTwo() {
        pair.sideTwoFrames = []
        step = .sideTwoAlignment
    }

    func startOver() {
        finishCorpusExport()
        store.delete(persistedSession)
        persistedSession = nil
        pair = CapturedPair(sessionID: UUID(), sideOneFrames: [], sideTwoFrames: [])
        camera.resetPairConfiguration()
        corpusExportConsented = false
        message = nil
        step = .setup
    }
}
