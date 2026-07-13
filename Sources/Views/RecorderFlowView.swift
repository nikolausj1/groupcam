import SwiftUI

struct RecorderFlowView: View {
    @ObservedObject var model: RecorderViewModel
    @State private var confirmStartOver = false

    var body: some View {
        ZStack {
            GroupCamTheme.ink.ignoresSafeArea()

            switch model.step {
            case .setup:
                SetupView(model: model)
            case .sideOneInstructions:
                InstructionView(
                    eyebrow: "PHOTOGRAPHER A",
                    title: "Leave yourself a spot",
                    message: "Stand near one outside edge. Ask everyone to hold their pose, then take the first photo. Stay put while the phone is handed to Photographer B.",
                    actionTitle: "I’m ready",
                    action: { model.step = .sideOneCapture }
                )
            case .sideOneCapture:
                CaptureView(model: model, side: .one)
            case .handoff:
                InstructionView(
                    eyebrow: "HAND OFF THE PHONE",
                    title: "Photographer A, wait here",
                    message: "Photographer B should come to the phone. Once they have it, Photographer A joins the open outside edge—like changing turns in HORSE.",
                    actionTitle: "B has the phone",
                    action: { model.step = .sideTwoAlignment }
                )
            case .sideTwoAlignment:
                CaptureView(model: model, side: .two)
            case .sideTwoCapture:
                CaptureView(model: model, side: .two)
            case .review:
                RecorderReviewView(model: model)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.step != .setup && model.step != .review {
                Button("Cancel") { confirmStartOver = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding()
            }
        }
        .alert("Delete this capture session?", isPresented: $confirmStartOver) {
            Button("Keep Working", role: .cancel) {}
            Button("Delete Session", role: .destructive) { model.startOver() }
        } message: {
            Text("Temporary source frames and logs for this session will be removed.")
        }
    }
}

private struct SetupView: View {
    @ObservedObject var model: RecorderViewModel

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            ScrollView {
                if isLandscape {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 34) {
                            brandBlock(compact: true)
                                .frame(maxWidth: .infinity)
                            controlsBlock
                                .frame(maxWidth: 470)
                        }
                        VStack(spacing: 24) {
                            brandBlock(compact: true)
                            controlsBlock
                        }
                    }
                    .padding(.horizontal, 42)
                    .padding(.vertical, 24)
                    .frame(minHeight: geometry.size.height)
                } else {
                    VStack(spacing: 26) {
                        Spacer(minLength: 42)
                        brandBlock(compact: false)
                        controlsBlock
                        Spacer(minLength: 26)
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    @ViewBuilder
    private func brandBlock(compact: Bool) -> some View {
        VStack(spacing: compact ? 14 : 24) {
            ZStack {
                Circle()
                    .fill(GroupCamTheme.paper)
                    .frame(width: compact ? 80 : 104, height: compact ? 80 : 104)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 8)
                Image(systemName: "person.3.fill")
                    .font(.system(size: compact ? 32 : 42, weight: .semibold))
                    .foregroundStyle(GroupCamTheme.ink)
            }

            VStack(spacing: 6) {
                Text("groupCam")
                    .font(.system(size: compact ? 36 : 43, weight: .bold, design: .rounded))
                Text("Two photos. Everyone in.")
                    .font((compact ? Font.headline : Font.title3).weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Text("Take turns behind the same iPhone. groupCam keeps the full-resolution rear camera and guides both photographers into one natural group photo.")
                .font(compact ? .subheadline : .body)
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
    }

    private var controlsBlock: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                Text("PROTOTYPE RECORDER")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(GroupCamTheme.brass)

                HStack {
                    Text("Lens")
                    Spacer()
                    Picker("Lens", selection: Binding(
                        get: { model.selectedLens },
                        set: { model.chooseLens($0) }
                    )) {
                        ForEach(model.camera.availableLenses) { lens in
                            Text(lens.label).tag(lens)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 170)
                }

                HStack {
                    Text("Frames per side")
                    Spacer()
                    Picker("Frames per side", selection: $model.sequenceLength) {
                        ForEach(SequenceLength.allCases) { length in
                            Text(length.label).tag(length)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Toggle(isOn: $model.everyoneConsented) {
                    Text("Everyone in frame agrees to be photographed")
                        .font(.subheadline)
                }
                .tint(GroupCamTheme.safe)
            }
            .padding(20)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))

            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(GroupCamTheme.warning)
                    .multilineTextAlignment(.leading)
            }

            Button {
                model.begin()
            } label: {
                HStack {
                    if model.isPreparingCamera { ProgressView().tint(.white) }
                    Text(model.isPreparingCamera ? "Opening camera…" : "Start a group photo")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RaisedButtonStyle())
            .disabled(model.isPreparingCamera)

            Text("Capture and processing stay on this iPhone. Photos leave the app only when you explicitly save or share them.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
        }
    }
}

private struct InstructionView: View {
    let eyebrow: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            if isLandscape {
                ScrollView {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 42) {
                            illustration(compact: true)
                            compactInstructionBlock
                                .frame(maxWidth: 560, alignment: .leading)
                        }
                        VStack(spacing: 22) {
                            illustration(compact: true)
                            compactInstructionBlock
                                .frame(maxWidth: 560, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    .padding(.horizontal, 56)
                    .padding(.vertical, 28)
                }
            } else {
                VStack(spacing: 28) {
                    Spacer()
                    illustration(compact: false)
                    instructionText(compact: false, alignment: .center)
                    Button(actionTitle, action: action)
                        .buttonStyle(RaisedButtonStyle())
                        .accessibilityHint("Continues to the camera")
                    Spacer()
                }
                .padding(30)
            }
        }
    }

    private var compactInstructionBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            instructionText(compact: true, alignment: .leading)
            Button(actionTitle, action: action)
                .buttonStyle(RaisedButtonStyle())
                .accessibilityHint("Continues to the camera")
        }
    }

    private func illustration(compact: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 26 : 34)
                .fill(GroupCamTheme.paper)
                .frame(width: compact ? 150 : 190, height: compact ? 112 : 142)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 10)
            Image(systemName: "arrow.left.and.right.circle.fill")
                .font(.system(size: compact ? 48 : 62))
                .foregroundStyle(GroupCamTheme.ink)
        }
    }

    private func instructionText(
        compact: Bool,
        alignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment == .leading ? .leading : .center, spacing: compact ? 8 : 12) {
            Text(eyebrow)
                .font(.caption.bold())
                .tracking(1.6)
                .foregroundStyle(GroupCamTheme.brass)
            Text(title)
                .font(compact ? .title.bold() : .largeTitle.bold())
                .multilineTextAlignment(alignment)
            Text(message)
                .font(compact ? .body : .title3)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(alignment)
                .lineSpacing(compact ? 2 : 4)
        }
    }
}

private struct CaptureView: View {
    @ObservedObject var model: RecorderViewModel
    let side: CaptureSide
    @State private var interfaceOrientation: UIInterfaceOrientation = .unknown
    @State private var zoomAtGestureStart: CGFloat?

    private var isSideTwo: Bool { side == .two }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            ZStack {
                cameraSurface
                onionSkin
                alignmentFrame(isLandscape: isLandscape)
                InterfaceOrientationReader { orientation in
                    interfaceOrientation = orientation
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                if isLandscape {
                    landscapeChrome
                } else {
                    portraitChrome
                }

                if model.isCapturing {
                    captureProgressOverlay(isLandscape: isLandscape)
                }
            }
        }
        .simultaneousGesture(zoomGesture)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.camera.captureProgress)
        .sensoryFeedback(.success, trigger: model.isCapturing == false && model.camera.captureProgress == 0)
    }

    @ViewBuilder
    private var cameraSurface: some View {
        if model.camera.usesFixtureCamera {
            LinearGradient(
                colors: [
                    Color(red: 0.40, green: 0.57, blue: 0.66),
                    Color(red: 0.13, green: 0.28, blue: 0.20)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        } else {
            CameraPreview(session: model.camera.session)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var onionSkin: some View {
        if isSideTwo, let image = model.onionSkinImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .opacity(0.26)
                .blendMode(.screen)
                .accessibilityHidden(true)
        }
    }

    private func alignmentFrame(isLandscape: Bool) -> some View {
        Rectangle()
            .strokeBorder(.white.opacity(0.38), lineWidth: 2)
            .padding(.leading, 28)
            .padding(.trailing, isLandscape ? 158 : 28)
            .padding(.vertical, isLandscape ? 26 : 120)
            .accessibilityHidden(true)
    }

    private var portraitChrome: some View {
        VStack {
            captureHeader(compact: false)
                .padding(.top, 14)
                .padding(.horizontal, 76)
            Spacer()
            portraitFooter
        }
    }

    private var landscapeChrome: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                captureHeader(compact: true)
                    .frame(maxWidth: 330, alignment: .leading)
                if let message = activeMessage {
                    warningMessage(message)
                }
                Spacer()
            }
            .padding(.leading, 24)
            .padding(.top, 18)
            .padding(.bottom, 18)

            Spacer(minLength: 12)
            landscapeControlRail
        }
    }

    private func captureHeader(compact: Bool) -> some View {
        VStack(spacing: 8) {
            Text(isSideTwo ? "MATCH THE FIRST VIEW" : "PHOTO 1 OF 2")
                .font(.caption.bold())
                .tracking(1.5)
            Text(isSideTwo ? "Line up the transparent scene" : "Keep yourself near an outside edge")
                .font(compact ? .subheadline.bold() : .headline)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 16 : 22)
        .padding(.vertical, compact ? 10 : 14)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: compact ? 14 : 18))
    }

    private var portraitFooter: some View {
        VStack(spacing: 14) {
            if let message = activeMessage {
                warningMessage(message)
            }

            HStack(spacing: 32) {
                lensControl
                shutterButton(size: 82)
                frameReadout
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.62))
    }

    private var landscapeControlRail: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 44)
            lensControl
            shutterButton(size: 74)
            frameReadout
            Spacer(minLength: 12)
        }
        .frame(width: 138)
        .background(.black.opacity(0.62))
    }

    private var lensControl: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(model.camera.availableLenses.sorted {
                    $0.baseMagnification < $1.baseMagnification
                }) { lens in
                    Button {
                        model.chooseLens(lens)
                    } label: {
                        Text(lens.label)
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .frame(width: 46, height: 34)
                            .background(
                                lens == model.selectedLens
                                    ? GroupCamTheme.brass
                                    : .black.opacity(0.46),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canAdjustFraming || isSideTwo)
                    .accessibilityLabel("Use \(lens.label) lens")
                    .accessibilityValue(
                        lens == model.selectedLens ? model.effectiveZoomLabel : "Available"
                    )
                }
            }
            Text(lensStatusText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.76))
        }
        .frame(width: 118)
        .accessibilityElement(children: .contain)
        .accessibilityValue(isSideTwo ? "Locked for Photo 2" : model.effectiveZoomLabel)
    }

    private var lensStatusText: String {
        if isSideTwo {
            return "\(model.effectiveZoomLabel) locked"
        }
        if abs(model.digitalZoomFactor - 1) > 0.01 {
            return "\(model.effectiveZoomLabel) • pinch"
        }
        return "pinch to zoom"
    }

    private var frameReadout: some View {
        VStack(spacing: 2) {
            Text("\(model.sequenceLength.rawValue)").font(.headline)
            Text("frames").font(.caption2)
        }
        .frame(width: 64)
    }

    private func shutterButton(size: CGFloat) -> some View {
        Button {
            model.capture(side: side, interfaceOrientation: interfaceOrientation)
        } label: {
            ZStack {
                Circle().fill(.white).frame(width: size, height: size)
                Circle()
                    .stroke(GroupCamTheme.ink, lineWidth: 4)
                    .frame(width: size - 14, height: size - 14)
            }
        }
        .disabled(model.isCapturing || orientationMismatchMessage != nil)
        .accessibilityLabel(isSideTwo ? "Capture second sequence" : "Capture first sequence")
    }

    private var orientationMismatchMessage: String? {
        if isSideTwo {
            return model.lockedOrientationMessage(for: interfaceOrientation)
        }
        guard interfaceOrientation == .unknown else { return nil }
        return "Hold the phone steady while groupCam reads its orientation."
    }

    private var activeMessage: String? {
        orientationMismatchMessage ?? model.message
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                guard !isSideTwo, model.canAdjustFraming else { return }
                if zoomAtGestureStart == nil {
                    zoomAtGestureStart = model.digitalZoomFactor
                }
                model.setZoomFactor((zoomAtGestureStart ?? 1) * magnification)
            }
            .onEnded { _ in
                zoomAtGestureStart = nil
            }
    }

    private func warningMessage(_ message: String) -> some View {
        Text(message)
            .font(.footnote.weight(.semibold))
            .padding(10)
            .background(GroupCamTheme.warning.opacity(0.92), in: Capsule())
    }

    private func captureProgressOverlay(isLandscape: Bool) -> some View {
        ZStack {
            Color.black.opacity(0.38).ignoresSafeArea()
            Group {
                if isLandscape {
                    HStack(spacing: 18) {
                        progressRing(size: 86)
                        Text("Capturing — hold steady")
                            .font(.title3.bold())
                    }
                } else {
                    VStack(spacing: 16) {
                        progressRing(size: 104)
                        Text("Capturing — hold steady")
                            .font(.title2.bold())
                    }
                }
            }
            .padding(22)
            .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 22))
        }
        .transition(.opacity)
    }

    private func progressRing(size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.24), lineWidth: 8)
            Circle()
                .trim(
                    from: 0,
                    to: CGFloat(model.camera.captureProgress) /
                        CGFloat(max(model.camera.captureTotal, 1))
                )
                .stroke(
                    GroupCamTheme.safe,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(model.camera.captureProgress)/\(model.camera.captureTotal)")
                .font(.title3.monospacedDigit().bold())
        }
        .frame(width: size, height: size)
    }
}
