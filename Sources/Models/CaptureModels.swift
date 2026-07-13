import Foundation
import UIKit

enum CaptureLens: String, CaseIterable, Codable, Identifiable {
    case wide
    case ultraWide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wide: "1×"
        case .ultraWide: "0.5×"
        }
    }

    var baseMagnification: CGFloat {
        switch self {
        case .wide: 1
        case .ultraWide: 0.5
        }
    }
}

enum SequenceLength: Int, CaseIterable, Codable, Identifiable {
    case single = 1
    case auto = 3
    case diagnostic = 5

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .single: "1"
        case .auto: "Auto 3"
        case .diagnostic: "5"
        }
    }
}

enum CaptureSide: String, Codable {
    case one
    case two
}

enum RecorderStep: Equatable {
    case setup
    case sideOneInstructions
    case sideOneCapture
    case handoff
    case sideTwoAlignment
    case sideTwoCapture
    case review
}

struct MotionSnapshot: Codable, Equatable, Sendable {
    let uptime: TimeInterval
    let roll: Double
    let pitch: Double
    let yaw: Double
    let rotationRateX: Double
    let rotationRateY: Double
    let rotationRateZ: Double
}

struct CaptureEvent: Codable, Equatable, Sendable {
    let name: String
    let uptime: TimeInterval
    let resolvedSettingsUniqueID: Int64
}

struct FrameMetadata: Codable, Identifiable, Equatable {
    let id: UUID
    let side: CaptureSide
    let sequenceIndex: Int
    let shutterIntentUptime: TimeInterval
    let callbackUptime: TimeInterval
    let capturedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let lens: CaptureLens
    let videoZoomFactor: Double?
    let motion: MotionSnapshot?
    let exposureDurationSeconds: Double?
    let iso: Float?
    let whiteBalanceRedGain: Float?
    let whiteBalanceGreenGain: Float?
    let whiteBalanceBlueGain: Float?
    let lensPosition: Float?
    let captureMetadataPropertyList: Data?
}

struct CapturedFrame: Identifiable {
    let metadata: FrameMetadata
    let imageData: Data

    var id: UUID { metadata.id }
    var image: UIImage? { UIImage(data: imageData) }
}

struct CapturedPair {
    let sessionID: UUID
    var sideOneFrames: [CapturedFrame]
    var sideTwoFrames: [CapturedFrame]

    var provisionalSideOne: CapturedFrame? {
        sideOneFrames.max {
            ($0.metadata.pixelWidth * $0.metadata.pixelHeight) <
            ($1.metadata.pixelWidth * $1.metadata.pixelHeight)
        }
    }

    var provisionalSideTwo: CapturedFrame? {
        sideTwoFrames.max {
            ($0.metadata.pixelWidth * $0.metadata.pixelHeight) <
            ($1.metadata.pixelWidth * $1.metadata.pixelHeight)
        }
    }
}

struct CaptureConfigurationSnapshot: Codable, Equatable {
    let lens: CaptureLens
    let videoZoomFactor: Double?
    let rotationAngleDegrees: Double
    let requestedMaxPhotoWidth: Int32
    let requestedMaxPhotoHeight: Int32
    let lensPosition: Float
    let exposureDurationSeconds: Double
    let iso: Float
    let whiteBalanceRedGain: Float
    let whiteBalanceGreenGain: Float
    let whiteBalanceBlueGain: Float
}
