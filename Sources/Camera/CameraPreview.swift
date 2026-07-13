import AVFoundation
import SwiftUI
import UIKit

enum CameraInterfaceRotation {
    nonisolated static func angle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .landscapeRight: 0
        case .portrait: 90
        case .landscapeLeft: 180
        case .portraitUpsideDown: 270
        default: 90
        }
    }

    nonisolated static func matches(
        expectedAngle: Double,
        orientation: UIInterfaceOrientation
    ) -> Bool {
        guard orientation != .unknown else { return false }
        return Double(angle(for: orientation)) == expectedAngle
    }
}

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePreviewRotation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePreviewRotation()
    }

    private func updatePreviewRotation() {
        guard let orientation = window?.windowScene?.interfaceOrientation,
              let connection = previewLayer.connection else { return }
        let angle = CameraInterfaceRotation.angle(for: orientation)
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
}

final class InterfaceOrientationObserverUIView: UIView {
    var onChange: ((UIInterfaceOrientation) -> Void)?
    private var lastOrientation: UIInterfaceOrientation = .unknown

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportOrientationIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportOrientationIfNeeded()
    }

    func reportOrientationIfNeeded() {
        guard let orientation = window?.windowScene?.interfaceOrientation,
              orientation != .unknown,
              orientation != lastOrientation else { return }
        lastOrientation = orientation
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(orientation)
        }
    }
}

struct InterfaceOrientationReader: UIViewRepresentable {
    let onChange: (UIInterfaceOrientation) -> Void

    func makeUIView(context: Context) -> InterfaceOrientationObserverUIView {
        let view = InterfaceOrientationObserverUIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: InterfaceOrientationObserverUIView, context: Context) {
        uiView.onChange = onChange
        uiView.reportOrientationIfNeeded()
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer.session = session
    }
}
