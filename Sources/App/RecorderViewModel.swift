import Foundation
import SwiftUI
import UIKit

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var step: RecorderStep = .setup
    @Published var selectedLens: CaptureLens = .wide
    @Published private(set) var digitalZoomFactor: CGFloat = 1
    @Published var sequenceLength: SequenceLength = .auto
    @Published var everyoneConsented = false
    @Published var corpusExportConsented = false
    @Published var pair = CapturedPair(sessionID: UUID(), sideOneFrames: [], sideTwoFrames: [])
    @Published var persistedSession: PersistedSession?
    @Published var compositeOutput: CompositeOutput?
    @Published var corpusArchiveURL: URL?
    @Published var isPreparingCamera = false
    @Published var isChangingLens = false
    @Published var isCapturing = false
    @Published var isCompositing = false
    @Published var message: String?

    let camera = CameraRecorder()
    private let store = SessionStore()
    private let compositor = GroupPhotoCompositor()
    private var compositingTask: Task<Void, Never>?

    init() {
        store.cleanupExpiredSessions()
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        if arguments.contains("-demoCapture"),
           environment["GROUPCAM_UI_TESTING"] == "1" {
            everyoneConsented = true
            step = .sideOneCapture
        } else if arguments.contains("-demoSideTwo"),
                  environment["GROUPCAM_UI_TESTING"] == "1" {
            let rotation = Double(environment["GROUPCAM_LOCKED_ROTATION"] ?? "") ?? 90
            camera.prepareUITestPairConfiguration(rotationAngleDegrees: rotation)
            everyoneConsented = true
            step = .sideTwoAlignment
        } else if arguments.contains("-demoProcessing"),
                  environment["GROUPCAM_UI_TESTING"] == "1" {
            step = .processing
        } else if arguments.contains("-demoReview"),
                  environment["GROUPCAM_UI_TESTING"] == "1" {
            compositeOutput = Self.demoCompositeOutput()
            step = .review
        }
        #endif
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

    var canAdjustFraming: Bool {
        camera.pairConfiguration == nil && !isCapturing && !isChangingLens
    }

    var effectiveZoomLabel: String {
        let effectiveZoom = selectedLens.baseMagnification * digitalZoomFactor
        if abs(effectiveZoom.rounded() - effectiveZoom) < 0.05 {
            return "\(Int(effectiveZoom.rounded()))×"
        }
        return String(format: "%.1f×", Double(effectiveZoom))
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
        guard canAdjustFraming else { return }
        if lens == selectedLens {
            setZoomFactor(1)
            return
        }
        isChangingLens = true
        Task {
            do {
                try await camera.switchLens(to: lens)
                selectedLens = lens
                digitalZoomFactor = camera.zoomFactor
                message = nil
            } catch {
                message = error.localizedDescription
            }
            isChangingLens = false
        }
    }

    func setZoomFactor(_ factor: CGFloat) {
        guard canAdjustFraming else { return }
        camera.setZoomFactor(factor)
        digitalZoomFactor = camera.zoomFactor
    }

    func lockedOrientationMessage(for orientation: UIInterfaceOrientation) -> String? {
        guard let expected = camera.pairConfiguration?.rotationAngleDegrees else { return nil }
        guard orientation != .unknown else {
            return "Hold the phone as it was for Photo 1."
        }
        guard !CameraInterfaceRotation.matches(
            expectedAngle: expected,
            orientation: orientation
        ) else { return nil }
        let layout = expected == 0 || expected == 180 ? "landscape" : "portrait"
        return "Rotate back to the same \(layout) direction as Photo 1."
    }

    func capture(side: CaptureSide, interfaceOrientation: UIInterfaceOrientation) {
        guard !isCapturing, !isChangingLens, interfaceOrientation != .unknown else { return }
        if side == .two,
           lockedOrientationMessage(for: interfaceOrientation) != nil {
            return
        }
        isCapturing = true
        message = nil
        camera.captureSequence(
            side: side,
            count: sequenceLength.rawValue,
            interfaceRotationAngleDegrees: Double(
                CameraInterfaceRotation.angle(for: interfaceOrientation)
            )
        ) { [weak self] result in
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
                        processCapturedPair()
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
        compositingTask?.cancel()
        store.delete(persistedSession)
        persistedSession = nil
        compositeOutput = nil
        isCompositing = false
        pair.sideTwoFrames = []
        step = .sideTwoAlignment
    }

    func retryComposite() {
        processCapturedPair()
    }

    func startOver() {
        compositingTask?.cancel()
        finishCorpusExport()
        store.delete(persistedSession)
        persistedSession = nil
        pair = CapturedPair(sessionID: UUID(), sideOneFrames: [], sideTwoFrames: [])
        compositeOutput = nil
        isCompositing = false
        camera.resetPairConfiguration()
        digitalZoomFactor = camera.zoomFactor
        corpusExportConsented = false
        message = nil
        step = .setup
    }

    private func processCapturedPair() {
        let sessionID = pair.sessionID
        let capturedPair = pair
        compositeOutput = nil
        message = nil
        isCompositing = true
        step = .processing
        compositingTask?.cancel()
        compositingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await compositor.composite(pair: capturedPair)
                guard !Task.isCancelled, pair.sessionID == sessionID else { return }
                compositeOutput = output
            } catch {
                guard !Task.isCancelled, pair.sessionID == sessionID else { return }
                message = error.localizedDescription
            }
            guard pair.sessionID == sessionID else { return }
            isCompositing = false
            step = .review
        }
    }

    #if DEBUG
    private static func demoCompositeOutput() -> CompositeOutput {
        let size = CGSize(width: 1_200, height: 800)
        let renderer = UIGraphicsImageRenderer(size: size)
        let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor(red: 0.18, green: 0.25, blue: 0.28, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let symbol = UIImage(systemName: "person.3.fill")?.withTintColor(
                .white,
                renderingMode: .alwaysOriginal
            )
            symbol?.draw(in: CGRect(x: 450, y: 250, width: 300, height: 300))
        }
        return CompositeOutput(
            jpegData: data,
            diagnostics: CompositeDiagnostics(
                baseSide: .two,
                selectedSideOneIndex: 0,
                selectedSideTwoIndex: 0,
                sideOnePeople: 3,
                sideTwoPeople: 3,
                registrationConfidence: 1,
                missingPersonOverlap: 0,
                donorTouchesOutputEdge: false
            )
        )
    }
    #endif
}
