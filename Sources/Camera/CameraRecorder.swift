@preconcurrency import AVFoundation
import Combine
@preconcurrency import CoreMotion
import Foundation
import UIKit

enum CameraRecorderError: LocalizedError {
    case permissionDenied
    case cameraUnavailable
    case configurationFailed
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Camera access is required to record a groupCam session."
        case .cameraUnavailable: "The selected rear camera is not available on this iPhone."
        case .configurationFailed: "The camera could not be configured."
        case .captureFailed: "The photo sequence did not complete."
        }
    }
}

@MainActor
final class CameraRecorder: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var availableLenses: [CaptureLens] = [.wide]
    @Published private(set) var isConfigured = false
    @Published private(set) var isRunning = false
    @Published private(set) var captureProgress = 0
    @Published private(set) var captureTotal = 0
    @Published private(set) var lastError: String?
    @Published private(set) var pairConfiguration: CaptureConfigurationSnapshot?
    @Published private(set) var captureEvents: [CaptureEvent] = []

    #if targetEnvironment(simulator)
    let usesFixtureCamera = true
    #else
    let usesFixtureCamera = false
    #endif

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.levelup.groupcam.camera-session")
    private let motionManager = CMMotionManager()
    private let motionBuffer = MotionBuffer()
    private var activeDevice: AVCaptureDevice?
    private var activeLens: CaptureLens = .wide
    private var pendingSide: CaptureSide = .one
    private var shutterIntentUptime: TimeInterval = 0
    private var pendingFrames: [CapturedFrame] = []
    private var completion: ((Result<[CapturedFrame], Error>) -> Void)?

    override init() {
        super.init()
        discoverLenses()
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        let motionBuffer = motionBuffer
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: OperationQueue()) { motion, _ in
            guard let motion else { return }
            motionBuffer.append(
                MotionSnapshot(
                    uptime: ProcessInfo.processInfo.systemUptime,
                    roll: motion.attitude.roll,
                    pitch: motion.attitude.pitch,
                    yaw: motion.attitude.yaw,
                    rotationRateX: motion.rotationRate.x,
                    rotationRateY: motion.rotationRate.y,
                    rotationRateZ: motion.rotationRate.z
                )
            )
        }
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }

    func requestAccessAndConfigure(lens: CaptureLens) async throws {
        #if targetEnvironment(simulator)
        activeLens = lens
        availableLenses = CaptureLens.allCases
        isConfigured = true
        isRunning = true
        return
        #else
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let granted: Bool
        switch status {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            granted = false
        }

        guard granted else { throw CameraRecorderError.permissionDenied }
        try configureSession(lens: lens)
        startSession()
        #endif
    }

    func switchLens(to lens: CaptureLens) throws {
        #if targetEnvironment(simulator)
        activeLens = lens
        #else
        guard !isRunning || pairConfiguration == nil else { return }
        try configureSession(lens: lens)
        #endif
    }

    func stopSession() {
        let captureSession = session
        sessionQueue.async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
        isRunning = false
    }

    func resetPairConfiguration() {
        pairConfiguration = nil
        captureEvents = []
        motionBuffer.reset()
    }

    var recordedMotionSamples: [MotionSnapshot] { motionBuffer.snapshot() }

    func captureSequence(
        side: CaptureSide,
        count: Int,
        completion: @escaping (Result<[CapturedFrame], Error>) -> Void
    ) {
        guard count > 0 else {
            completion(.failure(CameraRecorderError.captureFailed))
            return
        }

        self.completion = completion
        pendingFrames = []
        pendingSide = side
        captureProgress = 0
        captureTotal = count
        lastError = nil

        #if targetEnvironment(simulator)
        captureFixtureSequence(side: side, count: count)
        #else
        guard isConfigured, session.isRunning else {
            finish(.failure(CameraRecorderError.configurationFailed))
            return
        }

        do {
            if side == .one {
                captureEvents = []
                motionBuffer.reset()
                pairConfiguration = try lockPairConfiguration()
                captureNextPhoto()
            } else {
                try reapplyPairConfiguration()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: .milliseconds(450))
                    do {
                        try lockRefocusedPosition()
                        captureNextPhoto()
                    } catch {
                        finish(.failure(error))
                    }
                }
            }
        } catch {
            finish(.failure(error))
        }
        #endif
    }

    private func discoverLenses() {
        #if targetEnvironment(simulator)
        availableLenses = CaptureLens.allCases
        #else
        var lenses: [CaptureLens] = []
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil {
            lenses.append(.wide)
        }
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil {
            lenses.append(.ultraWide)
        }
        availableLenses = lenses
        #endif
    }

    private func configureSession(lens: CaptureLens) throws {
        let deviceType: AVCaptureDevice.DeviceType = lens == .wide ? .builtInWideAngleCamera : .builtInUltraWideCamera
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: .back) else {
            throw CameraRecorderError.cameraUnavailable
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        for input in session.inputs {
            session.removeInput(input)
        }
        if session.outputs.contains(photoOutput) {
            session.removeOutput(photoOutput)
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw CameraRecorderError.configurationFailed
        }

        session.addInput(input)
        session.addOutput(photoOutput)

        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }) {
            photoOutput.maxPhotoDimensions = largest
        }

        activeDevice = device
        activeLens = lens
        isConfigured = true
    }

    private func startSession() {
        let captureSession = session
        sessionQueue.async {
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        }
        isRunning = true
    }

    private func lockPairConfiguration() throws -> CaptureConfigurationSnapshot {
        guard let device = activeDevice else { throw CameraRecorderError.configurationFailed }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let gains = device.deviceWhiteBalanceGains
        let snapshot = CaptureConfigurationSnapshot(
            lens: activeLens,
            rotationAngleDegrees: currentRotationAngle(),
            requestedMaxPhotoWidth: photoOutput.maxPhotoDimensions.width,
            requestedMaxPhotoHeight: photoOutput.maxPhotoDimensions.height,
            lensPosition: device.lensPosition,
            exposureDurationSeconds: device.exposureDuration.seconds,
            iso: device.iso,
            whiteBalanceRedGain: gains.redGain,
            whiteBalanceGreenGain: gains.greenGain,
            whiteBalanceBlueGain: gains.blueGain
        )

        if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
        if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
        return snapshot
    }

    private func reapplyPairConfiguration() throws {
        guard let device = activeDevice, let snapshot = pairConfiguration else {
            throw CameraRecorderError.configurationFailed
        }
        guard snapshot.lens == activeLens else { throw CameraRecorderError.configurationFailed }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isExposureModeSupported(.custom) {
            device.setExposureModeCustom(
                duration: CMTime(seconds: snapshot.exposureDurationSeconds, preferredTimescale: 1_000_000_000),
                iso: snapshot.iso
            )
        }

        let gains = clampedWhiteBalanceGains(
            AVCaptureDevice.WhiteBalanceGains(
                redGain: snapshot.whiteBalanceRedGain,
                greenGain: snapshot.whiteBalanceGreenGain,
                blueGain: snapshot.whiteBalanceBlueGain
            ),
            device: device
        )
        if device.isWhiteBalanceModeSupported(.locked) {
            device.setWhiteBalanceModeLocked(with: gains)
        }

        if device.isFocusModeSupported(.autoFocus) {
            device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            device.focusMode = .autoFocus
        } else if device.isFocusModeSupported(.locked) {
            device.setFocusModeLocked(lensPosition: snapshot.lensPosition)
        }
    }

    private func lockRefocusedPosition() throws {
        guard let device = activeDevice else { throw CameraRecorderError.configurationFailed }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
    }

    private func clampedWhiteBalanceGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        device: AVCaptureDevice
    ) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = device.maxWhiteBalanceGain
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: min(max(gains.redGain, 1), maxGain),
            greenGain: min(max(gains.greenGain, 1), maxGain),
            blueGain: min(max(gains.blueGain, 1), maxGain)
        )
    }

    private func captureNextPhoto() {
        guard captureProgress < captureTotal else {
            finish(.success(pendingFrames))
            return
        }

        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.flashMode = .off
        settings.photoQualityPrioritization = .quality
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        if let angle = pairConfiguration?.rotationAngleDegrees,
           let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(CGFloat(angle)) {
            connection.videoRotationAngle = CGFloat(angle)
        }
        shutterIntentUptime = ProcessInfo.processInfo.systemUptime
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func motionSnapshot() -> MotionSnapshot? {
        motionBuffer.snapshot().last
    }

    private func currentRotationAngle() -> Double {
        switch UIDevice.current.orientation {
        case .landscapeLeft: 0
        case .landscapeRight: 180
        case .portraitUpsideDown: 270
        default: 90
        }
    }

    private func finish(_ result: Result<[CapturedFrame], Error>) {
        let handler = completion
        completion = nil
        captureTotal = 0
        captureProgress = 0
        if case .failure(let error) = result {
            lastError = error.localizedDescription
        }
        handler?(result)
    }

    private func captureFixtureSequence(side: CaptureSide, count: Int) {
        Task { @MainActor in
            for index in 0..<count {
                shutterIntentUptime = ProcessInfo.processInfo.systemUptime
                try? await Task.sleep(for: .milliseconds(320))
                guard let data = FixtureSceneRenderer.image(side: side, variation: index).jpegData(compressionQuality: 0.94) else {
                    finish(.failure(CameraRecorderError.captureFailed))
                    return
                }
                let image = UIImage(data: data)
                let frame = CapturedFrame(
                    metadata: FrameMetadata(
                        id: UUID(),
                        side: side,
                        sequenceIndex: index,
                        shutterIntentUptime: shutterIntentUptime,
                        callbackUptime: ProcessInfo.processInfo.systemUptime,
                        capturedAt: Date(),
                        pixelWidth: Int(image?.size.width ?? 0),
                        pixelHeight: Int(image?.size.height ?? 0),
                        lens: activeLens,
                        motion: nil,
                        exposureDurationSeconds: 1.0 / 120.0,
                        iso: 50,
                        whiteBalanceRedGain: 1,
                        whiteBalanceGreenGain: 1,
                        whiteBalanceBlueGain: 1,
                        lensPosition: 0.5,
                        captureMetadataPropertyList: nil
                    ),
                    imageData: data
                )
                pendingFrames.append(frame)
                captureProgress = index + 1
            }
            finish(.success(pendingFrames))
        }
    }
}

extension CameraRecorder: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        recordCaptureEvent("willBeginCapture", settings: resolvedSettings)
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        recordCaptureEvent("willCapturePhoto", settings: resolvedSettings)
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        recordCaptureEvent("didFinishProcessingPhoto", settings: photo.resolvedSettings)
        let data = photo.fileDataRepresentation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                finish(.failure(error))
                return
            }
            guard let data, let image = UIImage(data: data) else {
                finish(.failure(CameraRecorderError.captureFailed))
                return
            }

            let device = activeDevice
            let gains = device?.deviceWhiteBalanceGains
            let index = captureProgress
            pendingFrames.append(
                CapturedFrame(
                    metadata: FrameMetadata(
                        id: UUID(),
                        side: pendingSide,
                        sequenceIndex: index,
                        shutterIntentUptime: shutterIntentUptime,
                        callbackUptime: ProcessInfo.processInfo.systemUptime,
                        capturedAt: Date(),
                        pixelWidth: Int(image.size.width),
                        pixelHeight: Int(image.size.height),
                        lens: activeLens,
                        motion: motionSnapshot(),
                        exposureDurationSeconds: device?.exposureDuration.seconds,
                        iso: device?.iso,
                        whiteBalanceRedGain: gains?.redGain,
                        whiteBalanceGreenGain: gains?.greenGain,
                        whiteBalanceBlueGain: gains?.blueGain,
                        lensPosition: device?.lensPosition,
                        captureMetadataPropertyList: try? PropertyListSerialization.data(
                            fromPropertyList: photo.metadata,
                            format: .binary,
                            options: 0
                        )
                    ),
                    imageData: data
                )
            )
            captureProgress += 1
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: (any Error)?
    ) {
        let event = CaptureEvent(
            name: error == nil ? "didFinishCapture" : "didFinishCaptureWithError",
            uptime: ProcessInfo.processInfo.systemUptime,
            resolvedSettingsUniqueID: resolvedSettings.uniqueID
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            captureEvents.append(event)
            if let error {
                finish(.failure(error))
            } else if captureProgress >= captureTotal {
                finish(.success(pendingFrames))
            } else {
                try? await Task.sleep(for: .milliseconds(180))
                captureNextPhoto()
            }
        }
    }

    nonisolated private func recordCaptureEvent(
        _ name: String,
        settings: AVCaptureResolvedPhotoSettings
    ) {
        let event = CaptureEvent(
            name: name,
            uptime: ProcessInfo.processInfo.systemUptime,
            resolvedSettingsUniqueID: settings.uniqueID
        )
        Task { @MainActor [weak self] in
            self?.captureEvents.append(event)
        }
    }
}

private final class MotionBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [MotionSnapshot] = []

    func append(_ sample: MotionSnapshot) {
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    func snapshot() -> [MotionSnapshot] {
        lock.lock()
        let copy = samples
        lock.unlock()
        return copy
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

private enum FixtureSceneRenderer {
    static func image(side: CaptureSide, variation: Int) -> UIImage {
        let size = CGSize(width: 1200, height: 1600)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            UIColor(red: 0.65, green: 0.78, blue: 0.83, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            UIColor(red: 0.22, green: 0.42, blue: 0.28, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 850, width: size.width, height: 750))

            UIColor.white.withAlphaComponent(0.7).setFill()
            for x in stride(from: 70.0, through: 1100.0, by: 210.0) {
                cg.fillEllipse(in: CGRect(x: x, y: 200 + Double(variation * 3), width: 120, height: 65))
            }

            let peopleX: [CGFloat]
            switch side {
            case .one: peopleX = [230, 430, 630, 830, 1010]
            case .two: peopleX = [90, 280, 480, 680, 880]
            }

            let shirtColors: [UIColor] = [.systemRed, .systemBlue, .systemYellow, .systemPurple, .systemOrange]
            for (index, x) in peopleX.enumerated() {
                let offset = CGFloat((variation + index) % 2) * 4
                UIColor(red: 0.64, green: 0.41, blue: 0.28, alpha: 1).setFill()
                cg.fillEllipse(in: CGRect(x: x - 45, y: 660 + offset, width: 90, height: 100))
                shirtColors[index].setFill()
                cg.fillEllipse(in: CGRect(x: x - 74, y: 744 + offset, width: 148, height: 270))
            }

            UIColor.white.setFill()
            let label = side == .one ? "SIDE ONE FIXTURE" : "SIDE TWO FIXTURE"
            label.draw(
                at: CGPoint(x: 36, y: 48),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 34, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
            )
        }
    }
}
