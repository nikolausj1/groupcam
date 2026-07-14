import CoreGraphics
import CoreImage
import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif
import Vision
import simd

struct CompositeDiagnostics: Equatable, Sendable {
    let baseSide: CaptureSide
    let selectedSideOneIndex: Int
    let selectedSideTwoIndex: Int
    let sideOnePeople: Int
    let sideTwoPeople: Int
    let registrationConfidence: Float
    let missingPersonOverlap: Double
    let donorTouchesOutputEdge: Bool
}

struct CompositeOutput: Equatable, Sendable {
    let jpegData: Data
    let diagnostics: CompositeDiagnostics

    #if canImport(UIKit)
    var image: UIImage? { UIImage(data: jpegData) }
    #endif
}

enum GroupPhotoCompositorError: LocalizedError {
    case noFrames
    case unreadableFrame
    case mismatchedFrameDimensions
    case noFaces
    case noPeople
    case registrationFailed
    case backgroundMismatch
    case missingPersonNotDistinct(
        overlaps: [Double],
        masses: [Double],
        transform: String,
        confidence: Float
    )
    case donorSourceBoundaryIntersectsPerson
    case donorOutputBoundaryIntersectsPerson
    case renderingFailed
    case bothDirectionsFailed(sideOneBase: String, sideTwoBase: String)

    var errorDescription: String? {
        switch self {
        case .noFrames:
            "One of the two photo sequences is empty. Retake the session."
        case .unreadableFrame:
            "One of the captured photos could not be read. Retake that photo."
        case .mismatchedFrameDimensions:
            "The two camera views do not match closely enough. Retake Photo 2 from Photo 1’s position."
        case .noFaces:
            "groupCam could not find clear faces in one photo. Ask everyone to face the camera and retake it."
        case .noPeople:
            "groupCam could not separate the people in one photo. Try a cleaner background or more space between people."
        case .registrationFailed:
            "The camera moved too far during the handoff. Retake Photo 2 from closer to Photo 1’s position."
        case .backgroundMismatch:
            "The background changed too much between photos. Retake Photo 2 from Photo 1’s position and ask the group to hold still."
        case .missingPersonNotDistinct:
            "groupCam could not tell who changed places. Keep both photographers on opposite outside edges and retake."
        case .donorSourceBoundaryIntersectsPerson:
            "A photographer is too close to a source edge for a clean result. Leave a little more room and retake."
        case .donorOutputBoundaryIntersectsPerson:
            "A photographer would be cropped at the edge of the result. Leave more room around the group and retake."
        case .renderingFailed:
            "The combined preview could not be rendered."
        case .bothDirectionsFailed:
            "These photos cannot be combined cleanly yet. Retake Photo 2 from the same position and keep the two photographers on outside edges."
        }
    }
}

actor GroupPhotoCompositor {
    struct FrameQualitySummary: Equatable, Sendable {
        let detectedFaceCount: Int
        let scoredFaceCount: Int
        let minimumFaceQuality: Float
        let averageFaceQuality: Float
        let sequenceIndex: Int
    }

    private struct SelectedFrame: Sendable {
        let frame: CapturedFrame
        let quality: FrameQualitySummary
    }

    private struct PreparedFrame {
        let selected: SelectedFrame
        let image: CIImage
        let people: PersonAnalysis
    }

    private struct PersonAnalysis {
        let unionMask: CIImage
        let instanceMasks: [CIImage]
    }

    private struct Candidate {
        let image: CIImage
        let diagnostics: CompositeDiagnostics
    }

    private let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any,
    ])
    private let proxyLongEdge: CGFloat = 2_016

    func composite(pair: CapturedPair) async throws -> CompositeOutput {
        try Task.checkCancellation()
        guard !pair.sideOneFrames.isEmpty, !pair.sideTwoFrames.isEmpty else {
            throw GroupPhotoCompositorError.noFrames
        }

        async let selectedOneTask = rankFrames(pair.sideOneFrames)
        async let selectedTwoTask = rankFrames(pair.sideTwoFrames)
        let (selectedOne, selectedTwo) = try await (selectedOneTask, selectedTwoTask)
        try Task.checkCancellation()

        let framePairs = Self.rankedPairIndices(
            sideOneCount: selectedOne.count,
            sideTwoCount: selectedTwo.count
        )
        var preparedOne: [UUID: PreparedFrame] = [:]
        var preparedTwo: [UUID: PreparedFrame] = [:]
        var failedOne = Set<UUID>()
        var failedTwo = Set<UUID>()
        var sideOneFailure = "no viable frame pair"
        var sideTwoFailure = "no viable frame pair"
        var dimensionMismatchCount = 0

        for (oneRank, twoRank) in framePairs {
            try Task.checkCancellation()
            let oneSelection = selectedOne[oneRank]
            let twoSelection = selectedTwo[twoRank]
            guard !failedOne.contains(oneSelection.frame.id),
                  !failedTwo.contains(twoSelection.frame.id) else { continue }

            let one: PreparedFrame
            if let cached = preparedOne[oneSelection.frame.id] {
                one = cached
            } else {
                do {
                    one = try await prepare(oneSelection)
                    preparedOne[oneSelection.frame.id] = one
                } catch {
                    try Task.checkCancellation()
                    failedOne.insert(oneSelection.frame.id)
                    sideOneFailure = "frame \(oneSelection.frame.metadata.sequenceIndex): \(error)"
                    continue
                }
            }

            let two: PreparedFrame
            if let cached = preparedTwo[twoSelection.frame.id] {
                two = cached
            } else {
                do {
                    two = try await prepare(twoSelection)
                    preparedTwo[twoSelection.frame.id] = two
                } catch {
                    try Task.checkCancellation()
                    failedTwo.insert(twoSelection.frame.id)
                    sideTwoFailure = "frame \(twoSelection.frame.metadata.sequenceIndex): \(error)"
                    continue
                }
            }

            guard abs(one.image.extent.width - two.image.extent.width) <= 2,
                  abs(one.image.extent.height - two.image.extent.height) <= 2 else {
                dimensionMismatchCount += 1
                continue
            }
            let commonExtent = CGRect(
                x: 0,
                y: 0,
                width: floor(min(one.image.extent.width, two.image.extent.width)),
                height: floor(min(one.image.extent.height, two.image.extent.height))
            )
            let imageOne = one.image.cropped(to: commonExtent)
            let imageTwo = two.image.cropped(to: commonExtent)
            var candidates: [Candidate] = []
            do {
                candidates.append(
                    try await makeCandidate(
                        base: imageOne,
                        donor: imageTwo,
                        basePeople: one.people,
                        donorPeople: two.people,
                        baseSide: .one,
                        selectedSideOneIndex: one.selected.frame.metadata.sequenceIndex,
                        selectedSideTwoIndex: two.selected.frame.metadata.sequenceIndex
                    )
                )
            } catch {
                sideOneFailure = "frames \(one.selected.frame.metadata.sequenceIndex)/\(two.selected.frame.metadata.sequenceIndex): \(error)"
            }
            try Task.checkCancellation()
            do {
                candidates.append(
                    try await makeCandidate(
                        base: imageTwo,
                        donor: imageOne,
                        basePeople: two.people,
                        donorPeople: one.people,
                        baseSide: .two,
                        selectedSideOneIndex: one.selected.frame.metadata.sequenceIndex,
                        selectedSideTwoIndex: two.selected.frame.metadata.sequenceIndex
                    )
                )
            } catch {
                sideTwoFailure = "frames \(one.selected.frame.metadata.sequenceIndex)/\(two.selected.frame.metadata.sequenceIndex): \(error)"
            }
            guard let best = candidates.max(by: candidateIsWorse) else { continue }
            try Task.checkCancellation()

            let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
            let qualityKey = CIImageRepresentationOption(
                rawValue: kCGImageDestinationLossyCompressionQuality as String
            )
            guard let jpegData = context.jpegRepresentation(
                of: best.image,
                colorSpace: colorSpace,
                options: [qualityKey: 0.96]
            ) else {
                throw GroupPhotoCompositorError.renderingFailed
            }
            return CompositeOutput(jpegData: jpegData, diagnostics: best.diagnostics)
        }

        if dimensionMismatchCount == framePairs.count {
            throw GroupPhotoCompositorError.mismatchedFrameDimensions
        } else {
            throw GroupPhotoCompositorError.bothDirectionsFailed(
                sideOneBase: sideOneFailure,
                sideTwoBase: sideTwoFailure
            )
        }
    }

    private func rankFrames(_ frames: [CapturedFrame]) async throws -> [SelectedFrame] {
        var selections: [SelectedFrame] = []
        for frame in frames {
            try Task.checkCancellation()
            let handler = ImageRequestHandler(
                frame.imageData,
                orientation: Self.imageOrientation(in: frame.imageData)
            )
            let faces: [FaceObservation]
            do {
                faces = try await handler.perform(DetectFaceCaptureQualityRequest(.revision3))
            } catch {
                try Task.checkCancellation()
                continue
            }
            try Task.checkCancellation()
            let qualities = faces.compactMap { $0.captureQuality?.score }
            guard !faces.isEmpty else { continue }
            selections.append(
                SelectedFrame(
                    frame: frame,
                    quality: FrameQualitySummary(
                        detectedFaceCount: faces.count,
                        scoredFaceCount: qualities.count,
                        minimumFaceQuality: qualities.min() ?? -1,
                        averageFaceQuality: qualities.isEmpty
                            ? -1 : qualities.reduce(0, +) / Float(qualities.count),
                        sequenceIndex: frame.metadata.sequenceIndex
                    )
                )
            )
        }
        guard !selections.isEmpty else {
            throw GroupPhotoCompositorError.noFaces
        }
        let maximumDetectedFaceCount = selections.map(\.quality.detectedFaceCount).max() ?? 0
        return selections.sorted {
            Self.frameQualityIsWorse(
                $1.quality,
                than: $0.quality,
                maximumDetectedFaceCount: maximumDetectedFaceCount
            )
        }
    }

    static func frameQualityIsWorse(
        _ left: FrameQualitySummary,
        than right: FrameQualitySummary,
        maximumDetectedFaceCount: Int
    ) -> Bool {
        let leftComplete = left.detectedFaceCount == maximumDetectedFaceCount &&
            left.scoredFaceCount == left.detectedFaceCount
        let rightComplete = right.detectedFaceCount == maximumDetectedFaceCount &&
            right.scoredFaceCount == right.detectedFaceCount
        if leftComplete != rightComplete { return !leftComplete }
        if left.detectedFaceCount != right.detectedFaceCount {
            return left.detectedFaceCount < right.detectedFaceCount
        }
        let leftFullyScored = left.scoredFaceCount == left.detectedFaceCount
        let rightFullyScored = right.scoredFaceCount == right.detectedFaceCount
        if leftFullyScored != rightFullyScored { return !leftFullyScored }
        if left.minimumFaceQuality != right.minimumFaceQuality {
            return left.minimumFaceQuality < right.minimumFaceQuality
        }
        if left.averageFaceQuality != right.averageFaceQuality {
            return left.averageFaceQuality < right.averageFaceQuality
        }
        return left.sequenceIndex > right.sequenceIndex
    }

    static func rankedPairIndices(
        sideOneCount: Int,
        sideTwoCount: Int,
        limit: Int = 9
    ) -> [(Int, Int)] {
        guard sideOneCount > 0, sideTwoCount > 0, limit > 0 else { return [] }
        return (0..<sideOneCount).flatMap { one in
            (0..<sideTwoCount).map { two in (one, two) }
        }.sorted { left, right in
            let leftWorstRank = max(left.0, left.1)
            let rightWorstRank = max(right.0, right.1)
            if leftWorstRank != rightWorstRank { return leftWorstRank < rightWorstRank }
            let leftTotalRank = left.0 + left.1
            let rightTotalRank = right.0 + right.1
            if leftTotalRank != rightTotalRank { return leftTotalRank < rightTotalRank }
            if left.0 != right.0 { return left.0 < right.0 }
            return left.1 < right.1
        }.prefix(limit).map { $0 }
    }

    private func prepare(_ selected: SelectedFrame) async throws -> PreparedFrame {
        try Task.checkCancellation()
        let image = try proxyImage(from: selected.frame.imageData)
        let people = try await analyzePeople(in: image)
        try Task.checkCancellation()
        return PreparedFrame(selected: selected, image: image, people: people)
    }

    private func proxyImage(from data: Data) throws -> CIImage {
        guard var image = CIImage(
            data: data,
            options: [.applyOrientationProperty: true]
        ) else {
            throw GroupPhotoCompositorError.unreadableFrame
        }
        image = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
        )
        let longest = max(image.extent.width, image.extent.height)
        let scale = min(1, proxyLongEdge / longest)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return image.cropped(to: CGRect(origin: .zero, size: image.extent.size))
    }

    private func analyzePeople(in image: CIImage) async throws -> PersonAnalysis {
        let handler = ImageRequestHandler(image)
        guard let observation = try await handler.perform(GeneratePersonInstanceMaskRequest()),
              !observation.allInstances.isEmpty else {
            throw GroupPhotoCompositorError.noPeople
        }
        let unionBuffer = try observation.generateScaledMask(
            for: observation.allInstances,
            scaledToImageFrom: handler
        )
        let union = normalizedMask(CIImage(cvPixelBuffer: unionBuffer), to: image.extent)
        var instances: [CIImage] = []
        for instance in observation.allInstances {
            let buffer = try observation.generateScaledMask(
                for: IndexSet(integer: instance),
                scaledToImageFrom: handler
            )
            instances.append(normalizedMask(CIImage(cvPixelBuffer: buffer), to: image.extent))
        }
        guard !instances.isEmpty else { throw GroupPhotoCompositorError.noPeople }
        return PersonAnalysis(unionMask: union, instanceMasks: instances)
    }

    private func normalizedMask(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let normalized = mask.transformed(
            by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY)
        )
        let scale = CGAffineTransform(
            scaleX: extent.width / normalized.extent.width,
            y: extent.height / normalized.extent.height
        )
        return normalized.transformed(by: scale).cropped(to: extent)
    }

    private func makeCandidate(
        base: CIImage,
        donor: CIImage,
        basePeople: PersonAnalysis,
        donorPeople: PersonAnalysis,
        baseSide: CaptureSide,
        selectedSideOneIndex: Int,
        selectedSideTwoIndex: Int
    ) async throws -> Candidate {
        let extent = base.extent
        let sharedPeopleMask = basePeople.unionMask.applyingFilter(
            "CIAdditionCompositing",
            parameters: [kCIInputBackgroundImageKey: donorPeople.unionMask]
        ).cropped(to: extent)
        let registrationBase = backgroundRegistrationImage(
            base,
            suppressing: sharedPeopleMask,
            extent: extent
        )
        let registrationDonor = backgroundRegistrationImage(
            donor,
            suppressing: sharedPeopleMask,
            extent: extent
        )
        let handler = TargetedImageRequestHandler(
            source: registrationBase,
            target: registrationDonor
        )
        let alignment = try await handler.perform(TrackHomographicImageRegistrationRequest())
        try Task.checkCancellation()
        guard alignment.confidence >= 0.25,
              Self.alignmentIsPlausible(matrix: alignment.warpTransform, extent: extent) else {
            throw GroupPhotoCompositorError.registrationFailed
        }

        let warpedDonor = apply(alignment: alignment, to: donor).cropped(to: extent)
        let warpedDonorPeople = apply(
            alignment: alignment,
            to: donorPeople.unionMask
        ).cropped(to: extent)
        let fullWarpedInstances = donorPeople.instanceMasks.map {
            apply(alignment: alignment, to: $0)
        }
        let warpedInstances = fullWarpedInstances.map { $0.cropped(to: extent) }

        let white = CIImage(color: .white).cropped(to: donor.extent)
        let validDonor = apply(alignment: alignment, to: white).cropped(to: extent)
        let erodedValid = validDonor.applyingFilter(
            "CIMorphologyMinimum",
            parameters: ["inputRadius": 3.0]
        ).cropped(to: extent)
        try validateStaticBackground(
            base: base,
            warpedDonor: warpedDonor,
            basePeople: basePeople.unionMask,
            warpedDonorPeople: warpedDonorPeople,
            validDonor: erodedValid,
            extent: extent
        )

        let warpedMasses = warpedInstances.map {
            ((try? maskBytes($0, extent: extent)) ?? []).reduce(0) {
                $0 + Double($1) / 255.0
            }
        }
        let overlapScores = warpedInstances.map {
            (try? maskOverlap(foreground: $0, background: basePeople.unionMask, extent: extent)) ?? 1.0
        }
        guard let selectedIndex = overlapScores.indices.min(by: {
            overlapScores[$0] < overlapScores[$1]
        }), overlapScores[selectedIndex] < 0.45 else {
            throw GroupPhotoCompositorError.missingPersonNotDistinct(
                overlaps: overlapScores,
                masses: warpedMasses,
                transform: String(describing: alignment.warpTransform),
                confidence: alignment.confidence
            )
        }
        let donorMask = warpedInstances[selectedIndex]

        let donorBytes = try maskBytes(donorMask, extent: extent)
        let validBytes = try maskBytes(erodedValid, extent: extent)
        let width = Int(extent.width)
        let height = Int(extent.height)
        var sourceBoundaryContact = false
        var outputEdgeContact = false
        let edgeMargin = 3
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * width + x
                guard donorBytes[offset] >= 20 else { continue }
                let atOutputEdge = x < edgeMargin || y < edgeMargin ||
                    x >= width - edgeMargin || y >= height - edgeMargin
                if atOutputEdge {
                    outputEdgeContact = true
                } else if validBytes[offset] < 180 {
                    sourceBoundaryContact = true
                    break
                }
            }
            if sourceBoundaryContact { break }
        }
        guard !sourceBoundaryContact else {
            throw GroupPhotoCompositorError.donorSourceBoundaryIntersectsPerson
        }
        let containedAtOutputEdge: Bool
        if outputEdgeContact {
            containedAtOutputEdge = try donorMaskIsContained(
                fullMask: fullWarpedInstances[selectedIndex],
                croppedMaskBytes: donorBytes,
                outputExtent: extent
            )
        } else {
            containedAtOutputEdge = true
        }
        guard containedAtOutputEdge else {
            throw GroupPhotoCompositorError.donorOutputBoundaryIntersectsPerson
        }

        let softMask = donorMask
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.25])
            .cropped(to: extent)
        let composite = warpedDonor.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: base,
                kCIInputMaskImageKey: softMask,
            ]
        ).cropped(to: extent)
        return Candidate(
            image: composite,
            diagnostics: CompositeDiagnostics(
                baseSide: baseSide,
                selectedSideOneIndex: selectedSideOneIndex,
                selectedSideTwoIndex: selectedSideTwoIndex,
                sideOnePeople: baseSide == .one
                    ? basePeople.instanceMasks.count : donorPeople.instanceMasks.count,
                sideTwoPeople: baseSide == .two
                    ? basePeople.instanceMasks.count : donorPeople.instanceMasks.count,
                registrationConfidence: alignment.confidence,
                missingPersonOverlap: overlapScores[selectedIndex],
                donorTouchesOutputEdge: outputEdgeContact
            )
        )
    }

    private func donorMaskIsContained(
        fullMask: CIImage,
        croppedMaskBytes: [UInt8],
        outputExtent: CGRect
    ) throws -> Bool {
        let fullExtent = fullMask.extent.integral
        guard fullExtent.width > 0, fullExtent.height > 0,
              fullExtent.width * fullExtent.height <= outputExtent.width * outputExtent.height * 4
        else { return false }
        let fullBytes = try maskBytes(fullMask, extent: fullExtent)
        let fullMass = fullBytes.reduce(0.0) { $0 + Double($1) / 255.0 }
        let croppedMass = croppedMaskBytes.reduce(0.0) { $0 + Double($1) / 255.0 }
        guard fullMass > 100 else { return false }

        // Edge contact is safe only when projective cropping removed virtually
        // none of the source matte. This preserves an intentional source crop
        // while rejecting a newly cut-off photographer.
        return croppedMass / fullMass >= 0.995
    }

    private func backgroundRegistrationImage(
        _ image: CIImage,
        suppressing peopleMask: CIImage,
        extent: CGRect
    ) -> CIImage {
        // Both frames use the same union support so the swapped photographers
        // cannot become the sharp features that drive the homography.
        let expandedMask = peopleMask
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 18.0])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6.0])
            .cropped(to: extent)
        let lowFrequencyFill = image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 32.0])
            .cropped(to: extent)
        return lowFrequencyFill.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: expandedMask,
            ]
        ).cropped(to: extent)
    }

    private func validateStaticBackground(
        base: CIImage,
        warpedDonor: CIImage,
        basePeople: CIImage,
        warpedDonorPeople: CIImage,
        validDonor: CIImage,
        extent: CGRect
    ) throws {
        let exclusionRadius = max(8.0, min(extent.width, extent.height) * 0.008)
        let expandedBasePeople = basePeople.applyingFilter(
            "CIMorphologyMaximum",
            parameters: ["inputRadius": exclusionRadius]
        ).cropped(to: extent)
        let expandedDonorPeople = warpedDonorPeople.applyingFilter(
            "CIMorphologyMaximum",
            parameters: ["inputRadius": exclusionRadius]
        ).cropped(to: extent)
        let difference = warpedDonor.applyingFilter(
            "CIDifferenceBlendMode",
            parameters: [kCIInputBackgroundImageKey: base]
        ).applyingFilter(
            "CIColorControls",
            parameters: [kCIInputSaturationKey: 0.0]
        ).cropped(to: extent)

        let acceptable = Self.staticBackgroundIsAcceptable(
            difference: try maskBytes(difference, extent: extent),
            basePeople: try maskBytes(expandedBasePeople, extent: extent),
            donorPeople: try maskBytes(expandedDonorPeople, extent: extent),
            validDonor: try maskBytes(validDonor, extent: extent)
        )
        guard acceptable else { throw GroupPhotoCompositorError.backgroundMismatch }
    }

    static func staticBackgroundIsAcceptable(
        difference: [UInt8],
        basePeople: [UInt8],
        donorPeople: [UInt8],
        validDonor: [UInt8]
    ) -> Bool {
        guard !difference.isEmpty,
              difference.count == basePeople.count,
              difference.count == donorPeople.count,
              difference.count == validDonor.count else { return false }

        var histogram = [Int](repeating: 0, count: 256)
        var sampleCount = 0
        var totalDifference = 0
        for index in difference.indices where
            basePeople[index] < 20 && donorPeople[index] < 20 && validDonor[index] >= 200 {
            let value = Int(difference[index])
            histogram[value] += 1
            sampleCount += 1
            totalDifference += value
        }
        guard sampleCount >= max(1_000, difference.count / 12) else { return false }
        let meanDifference = Double(totalDifference) / Double(sampleCount) / 255.0
        let p90Target = Int(ceil(Double(sampleCount) * 0.9))
        var cumulative = 0
        var p90 = 255
        for value in histogram.indices {
            cumulative += histogram[value]
            if cumulative >= p90Target {
                p90 = value
                break
            }
        }
        return meanDifference <= 0.22 && Double(p90) / 255.0 <= 0.5
    }

    private func candidateIsWorse(_ left: Candidate, _ right: Candidate) -> Bool {
        if left.diagnostics.registrationConfidence != right.diagnostics.registrationConfidence {
            return left.diagnostics.registrationConfidence < right.diagnostics.registrationConfidence
        }
        if left.diagnostics.missingPersonOverlap != right.diagnostics.missingPersonOverlap {
            return left.diagnostics.missingPersonOverlap > right.diagnostics.missingPersonOverlap
        }
        return left.diagnostics.baseSide == .one && right.diagnostics.baseSide == .two
    }

    private func apply(
        alignment: ImageHomographicAlignmentObservation,
        to image: CIImage
    ) -> CIImage {
        let matrix = alignment.warpTransform
        func projected(_ point: CGPoint) -> CIVector {
            let source = SIMD3<Float>(Float(point.x), Float(point.y), 1)
            let destination = matrix * source
            let divisor = abs(destination.z) < 0.000_001 ? 0.000_001 : destination.z
            return CIVector(
                x: CGFloat(destination.x / divisor),
                y: CGFloat(destination.y / divisor)
            )
        }
        let extent = image.extent
        return image.applyingFilter(
            "CIPerspectiveTransform",
            parameters: [
                "inputTopLeft": projected(CGPoint(x: extent.minX, y: extent.maxY)),
                "inputTopRight": projected(CGPoint(x: extent.maxX, y: extent.maxY)),
                "inputBottomLeft": projected(CGPoint(x: extent.minX, y: extent.minY)),
                "inputBottomRight": projected(CGPoint(x: extent.maxX, y: extent.minY)),
            ]
        )
    }

    static func alignmentIsPlausible(
        matrix: simd_float3x3,
        extent: CGRect
    ) -> Bool {
        let sourceCorners = [
            SIMD3<Float>(Float(extent.minX), Float(extent.minY), 1),
            SIMD3<Float>(Float(extent.maxX), Float(extent.minY), 1),
            SIMD3<Float>(Float(extent.maxX), Float(extent.maxY), 1),
            SIMD3<Float>(Float(extent.minX), Float(extent.maxY), 1),
        ]
        let projected = sourceCorners.compactMap { source -> (CGPoint, Float)? in
            let destination = matrix * source
            guard destination.x.isFinite, destination.y.isFinite, destination.z.isFinite,
                  abs(destination.z) > 0.05 else { return nil }
            return (
                CGPoint(
                    x: CGFloat(destination.x / destination.z),
                    y: CGFloat(destination.y / destination.z)
                ),
                destination.z
            )
        }
        guard projected.count == 4,
              projected.allSatisfy({ $0.1.sign == projected[0].1.sign }) else { return false }
        let corners = projected.map(\.0)
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minimumX = xs.min(), let maximumX = xs.max(),
              let minimumY = ys.min(), let maximumY = ys.max() else { return false }
        let widthRatio = (maximumX - minimumX) / extent.width
        let heightRatio = (maximumY - minimumY) / extent.height
        guard (0.55...1.8).contains(widthRatio),
              (0.55...1.8).contains(heightRatio) else { return false }

        var doubledArea: CGFloat = 0
        for index in corners.indices {
            let next = corners[(index + 1) % corners.count]
            doubledArea += corners[index].x * next.y - next.x * corners[index].y
        }
        let areaRatio = abs(doubledArea) / 2 / (extent.width * extent.height)
        return (0.4...2.5).contains(areaRatio)
    }

    private static func imageOrientation(in data: Data) -> CGImagePropertyOrientation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let rawValue = properties[kCGImagePropertyOrientation] as? NSNumber else {
            return nil
        }
        return CGImagePropertyOrientation(rawValue: rawValue.uint32Value)
    }

    private func maskOverlap(
        foreground: CIImage,
        background: CIImage,
        extent: CGRect
    ) throws -> Double {
        let foregroundBytes = try maskBytes(foreground, extent: extent)
        let backgroundBytes = try maskBytes(background, extent: extent)
        var foregroundMass = 0.0
        var intersectionMass = 0.0
        for index in foregroundBytes.indices {
            let foregroundValue = Double(foregroundBytes[index]) / 255.0
            foregroundMass += foregroundValue
            intersectionMass += foregroundValue * Double(backgroundBytes[index]) / 255.0
        }
        guard foregroundMass > 100 else { throw GroupPhotoCompositorError.noPeople }
        return intersectionMass / foregroundMass
    }

    private func maskBytes(_ image: CIImage, extent: CGRect) throws -> [UInt8] {
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { throw GroupPhotoCompositorError.renderingFailed }
        var bytes = [UInt8](repeating: 0, count: width * height)
        context.render(
            image,
            toBitmap: &bytes,
            rowBytes: width,
            bounds: extent,
            format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )
        return bytes
    }
}
