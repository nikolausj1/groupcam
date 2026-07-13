@preconcurrency import AVFoundation
import Combine
@preconcurrency import CoreMotion
import Foundation
import UIKit

private struct CameraConfigurationResult: @unchecked Sendable {
    let device: AVCaptureDevice
    let maximumZoomFactor: CGFloat
    let sessionIsRunning: Bool
}

private final class ZoomRequestBuffer: @unchecked Sendable {
    struct Request {
        let device: AVCaptureDevice
        let factor: CGFloat
    }

    private let lock = NSLock()
    private var latest: Request?
    private var isScheduled = false

    func submit(_ request: Request) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        latest = request
        guard !isScheduled else { return false }
        isScheduled = true
        return true
    }

    func takeLatest() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        let request = latest
        latest = nil
        isScheduled = false
        return request
    }
}

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
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var maximumZoomFactor: CGFloat = 2
    @Published private(set) var pairConfiguration: CaptureConfigurationSnapshot?
    @Published private(set) var captureEvents: [CaptureEvent] = []

    #if targetEnvironment(simulator)
    let usesFixtureCamera = true
    #else
    let usesFixtureCamera = false
    #endif

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.levelup.groupcam.camera-session")
    private let zoomRequests = ZoomRequestBuffer()
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
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: OperationQueue(),
            withHandler: Self.makeMotionHandler(buffer: motionBuffer)
        )
    }

    nonisolated private static func makeMotionHandler(
        buffer: MotionBuffer
    ) -> CMDeviceMotionHandler {
        { motion, _ in
            guard let motion else { return }
            buffer.append(
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
        zoomFactor = 1
        maximumZoomFactor = 2
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
        try await configureAndStartSession(lens: lens)
        #endif
    }

    func switchLens(to lens: CaptureLens) async throws {
        #if targetEnvironment(simulator)
        guard pairConfiguration == nil, captureTotal == 0 else { return }
        activeLens = lens
        zoomFactor = 1
        #else
        guard pairConfiguration == nil, captureTotal == 0 else { return }
        try await configureAndStartSession(lens: lens)
        #endif
    }

    func setZoomFactor(_ requestedFactor: CGFloat) {
        guard pairConfiguration == nil, captureTotal == 0 else { return }
        let clamped = min(max(requestedFactor, 1), maximumZoomFactor)
        #if targetEnvironment(simulator)
        zoomFactor = clamped
        #else
        guard let device = activeDevice else { return }
        zoomFactor = clamped
        let request = ZoomRequestBuffer.Request(device: device, factor: clamped)
        guard zoomRequests.submit(request) else { return }
        let requests = zoomRequests
        sessionQueue.asyncAfter(deadline: .now() + .milliseconds(30)) {
            guard let latest = requests.takeLatest() else { return }
            do {
                try latest.device.lockForConfiguration()
                defer { latest.device.unlockForConfiguration() }
                latest.device.videoZoomFactor = min(
                    latest.factor,
                    latest.device.activeFormat.videoMaxZoomFactor
                )
            } catch {
                // A later gesture update or capture will retry the final zoom.
            }
        }
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    func prepareUITestPairConfiguration(rotationAngleDegrees: Double) {
        activeLens = .wide
        zoomFactor = 1
        pairConfiguration = CaptureConfigurationSnapshot(
            lens: .wide,
            videoZoomFactor: 1,
            rotationAngleDegrees: rotationAngleDegrees,
            requestedMaxPhotoWidth: 4_032,
            requestedMaxPhotoHeight: 3_024,
            lensPosition: 0.5,
            exposureDurationSeconds: 1.0 / 120.0,
            iso: 50,
            whiteBalanceRedGain: 1,
            whiteBalanceGreenGain: 1,
            whiteBalanceBlueGain: 1
        )
    }
    #endif

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
        setZoomFactor(1)
    }

    var recordedMotionSamples: [MotionSnapshot] { motionBuffer.snapshot() }

    func captureSequence(
        side: CaptureSide,
        count: Int,
        interfaceRotationAngleDegrees: Double,
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
        if side == .one {
            pairConfiguration = CaptureConfigurationSnapshot(
                lens: activeLens,
                videoZoomFactor: Double(zoomFactor),
                rotationAngleDegrees: interfaceRotationAngleDegrees,
                requestedMaxPhotoWidth: 4_032,
                requestedMaxPhotoHeight: 3_024,
                lensPosition: 0.5,
                exposureDurationSeconds: 1.0 / 120.0,
                iso: 50,
                whiteBalanceRedGain: 1,
                whiteBalanceGreenGain: 1,
                whiteBalanceBlueGain: 1
            )
        }
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
                pairConfiguration = try lockPairConfiguration(
                    rotationAngleDegrees: interfaceRotationAngleDegrees
                )
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

    private func configureAndStartSession(lens: CaptureLens) async throws {
        let captureSession = session
        let output = photoOutput
        let result: CameraConfigurationResult = try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    let configured = try Self.configureSessionGraph(
                        captureSession,
                        photoOutput: output,
                        lens: lens
                    )
                    if !captureSession.isRunning {
                        captureSession.startRunning()
                    }
                    continuation.resume(
                        returning: CameraConfigurationResult(
                            device: configured.device,
                            maximumZoomFactor: configured.maximumZoomFactor,
                            sessionIsRunning: captureSession.isRunning
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        activeDevice = result.device
        activeLens = lens
        zoomFactor = 1
        maximumZoomFactor = result.maximumZoomFactor
        isConfigured = true
        isRunning = result.sessionIsRunning
    }

    nonisolated private static func configureSessionGraph(
        _ session: AVCaptureSession,
        photoOutput: AVCapturePhotoOutput,
        lens: CaptureLens
    ) throws -> CameraConfigurationResult {
        let deviceType: AVCaptureDevice.DeviceType = lens == .wide ? .builtInWideAngleCamera : .builtInUltraWideCamera
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: .back) else {
            throw CameraRecorderError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        let priorVideoInputs = session.inputs.filter { input in
            guard let deviceInput = input as? AVCaptureDeviceInput else { return false }
            return deviceInput.device.hasMediaType(.video)
        }
        var addedInput = false
        var addedOutput = false
        var configured = false

        session.beginConfiguration()
        defer {
            if !configured {
                if addedInput {
                    session.removeInput(input)
                }
                if addedOutput {
                    session.removeOutput(photoOutput)
                }
                for priorInput in priorVideoInputs where session.canAddInput(priorInput) {
                    session.addInput(priorInput)
                }
            }
            session.commitConfiguration()
        }
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }

        for priorInput in priorVideoInputs {
            session.removeInput(priorInput)
        }
        guard session.canAddInput(input) else {
            throw CameraRecorderError.configurationFailed
        }
        session.addInput(input)
        addedInput = true

        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else {
                throw CameraRecorderError.configurationFailed
            }
            session.addOutput(photoOutput)
            addedOutput = true
        }
        // AVCapturePhotoOutput defaults to `.balanced`. Every per-shot settings
        // object below requests `.quality`, so raise the output ceiling before
        // capture; otherwise capturePhoto(with:delegate:) throws on device.
        photoOutput.maxPhotoQualityPrioritization = .quality

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.videoZoomFactor = 1
        let maximumZoomFactor = min(max(device.activeFormat.videoMaxZoomFactor, 1), 2)
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }) {
            photoOutput.maxPhotoDimensions = largest
        }
        configured = true
        return CameraConfigurationResult(
            device: device,
            maximumZoomFactor: maximumZoomFactor,
            sessionIsRunning: true
        )
    }

    private func lockPairConfiguration(
        rotationAngleDegrees: Double
    ) throws -> CaptureConfigurationSnapshot {
        guard let device = activeDevice else { throw CameraRecorderError.configurationFailed }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.videoZoomFactor = min(
            max(zoomFactor, 1),
            min(device.activeFormat.videoMaxZoomFactor, maximumZoomFactor)
        )
        let gains = device.deviceWhiteBalanceGains
        let snapshot = CaptureConfigurationSnapshot(
            lens: activeLens,
            videoZoomFactor: Double(device.videoZoomFactor),
            rotationAngleDegrees: rotationAngleDegrees,
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

        let requestedZoom = CGFloat(snapshot.videoZoomFactor ?? 1)
        device.videoZoomFactor = min(
            max(requestedZoom, 1),
            min(device.activeFormat.videoMaxZoomFactor, maximumZoomFactor)
        )
        zoomFactor = device.videoZoomFactor

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
                        videoZoomFactor: Double(zoomFactor),
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
                        videoZoomFactor: device.map { Double($0.videoZoomFactor) },
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
