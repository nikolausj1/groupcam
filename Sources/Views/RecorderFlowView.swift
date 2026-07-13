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
        ScrollView {
            VStack(spacing: 26) {
                Spacer(minLength: 42)

                ZStack {
                    Circle()
                        .fill(GroupCamTheme.paper)
                        .frame(width: 104, height: 104)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 8)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(GroupCamTheme.ink)
                }

                VStack(spacing: 8) {
                    Text("groupCam")
                        .font(.system(size: 43, weight: .bold, design: .rounded))
                    Text("Two photos. Everyone in.")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Text("Take turns behind the same iPhone. groupCam keeps the full-resolution rear camera and guides both photographers into one natural group photo.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)

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

                Spacer(minLength: 26)
            }
            .padding(.horizontal, 24)
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
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 34)
                    .fill(GroupCamTheme.paper)
                    .frame(width: 190, height: 142)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 10)
                Image(systemName: "arrow.left.and.right.circle.fill")
                    .font(.system(size: 62))
                    .foregroundStyle(GroupCamTheme.ink)
            }

            VStack(spacing: 12) {
                Text(eyebrow)
                    .font(.caption.bold())
                    .tracking(1.6)
                    .foregroundStyle(GroupCamTheme.brass)
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Button(actionTitle, action: action)
                .buttonStyle(RaisedButtonStyle())
                .accessibilityHint("Continues to the camera")
            Spacer()
        }
        .padding(30)
    }
}

private struct CaptureView: View {
    @ObservedObject var model: RecorderViewModel
    let side: CaptureSide

    private var isSideTwo: Bool { side == .two }

    var body: some View {
        ZStack {
            if model.camera.usesFixtureCamera {
                LinearGradient(
                    colors: [Color(red: 0.40, green: 0.57, blue: 0.66), Color(red: 0.13, green: 0.28, blue: 0.20)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            } else {
                CameraPreview(session: model.camera.session)
                    .ignoresSafeArea()
            }

            if isSideTwo, let image = model.onionSkinImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .opacity(0.26)
                    .blendMode(.screen)
                    .accessibilityHidden(true)
            }

            Rectangle()
                .strokeBorder(.white.opacity(0.38), lineWidth: 2)
                .padding(.horizontal, 28)
                .padding(.vertical, 120)
                .accessibilityHidden(true)

            VStack {
                captureHeader
                Spacer()
                captureFooter
            }

            if model.isCapturing {
                Color.black.opacity(0.32).ignoresSafeArea()
                VStack(spacing: 16) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.24), lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: CGFloat(model.camera.captureProgress) / CGFloat(max(model.camera.captureTotal, 1)))
                            .stroke(GroupCamTheme.safe, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(model.camera.captureProgress)/\(model.camera.captureTotal)")
                            .font(.title2.monospacedDigit().bold())
                    }
                    .frame(width: 104, height: 104)
                    Text("Capturing — hold steady")
                        .font(.title2.bold())
                }
                .transition(.opacity)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.camera.captureProgress)
        .sensoryFeedback(.success, trigger: model.isCapturing == false && model.camera.captureProgress == 0)
    }

    private var captureHeader: some View {
        VStack(spacing: 8) {
            Text(isSideTwo ? "MATCH THE FIRST VIEW" : "PHOTO 1 OF 2")
                .font(.caption.bold())
                .tracking(1.5)
            Text(isSideTwo ? "Line up the transparent scene" : "Keep yourself near an outside edge")
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 18))
        .padding(.top, 14)
        .padding(.horizontal, 76)
    }

    private var captureFooter: some View {
        VStack(spacing: 14) {
            if let message = model.message {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .padding(10)
                    .background(GroupCamTheme.warning.opacity(0.9), in: Capsule())
            }

            HStack(spacing: 32) {
                VStack(spacing: 2) {
                    Text(model.selectedLens.label).font(.headline)
                    Text("lens").font(.caption2)
                }
                .frame(width: 56)

                Button {
                    model.capture(side: side)
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 82, height: 82)
                        Circle().stroke(GroupCamTheme.ink, lineWidth: 4).frame(width: 68, height: 68)
                    }
                }
                .disabled(model.isCapturing)
                .accessibilityLabel(isSideTwo ? "Capture second sequence" : "Capture first sequence")

                VStack(spacing: 2) {
                    Text("\(model.sequenceLength.rawValue)").font(.headline)
                    Text("frames").font(.caption2)
                }
                .frame(width: 56)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.62))
    }
}
