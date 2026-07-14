import SwiftUI
import UIKit

struct RecorderReviewView: View {
    @ObservedObject var model: RecorderViewModel
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var confirmStartOver = false

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            ScrollView {
                VStack(spacing: isLandscape ? 16 : 22) {
                    heading
                    if let image = model.compositeOutput?.image {
                        resultPreview(image, isLandscape: isLandscape, availableHeight: geometry.size.height)
                        resultDetails
                        resultActions
                    } else {
                        failureCard
                        sourcePreviews
                    }

                    #if DEBUG
                    sourcePackageSummary
                    corpusExportControls
                    #endif

                    sessionActions
                }
                .frame(maxWidth: isLandscape ? 980 : 680)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, isLandscape ? 34 : 24)
                .padding(.vertical, isLandscape ? 18 : 24)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems) {
                showShareSheet = false
                shareItems = []
                model.finishCorpusExport()
            }
        }
        .alert("Delete this recorded session?", isPresented: $confirmStartOver) {
            Button("Keep It", role: .cancel) {}
            Button("Delete and Continue", role: .destructive) { model.startOver() }
        } message: {
            Text("This removes the app-private source frames and metadata. Any files you already exported are outside groupCam’s control.")
        }
    }

    private var heading: some View {
        VStack(spacing: 6) {
            Text(model.compositeOutput == nil ? "RETAKE RECOMMENDED" : "PROTOTYPE COMPOSITE")
                .font(.caption.bold())
                .tracking(1.6)
                .foregroundStyle(model.compositeOutput == nil ? GroupCamTheme.warning : GroupCamTheme.safe)
            Text(model.compositeOutput == nil ? "This pair needs another try" : "Review the result closely")
                .font(.largeTitle.bold())
            Text(
                model.compositeOutput == nil
                    ? "groupCam stopped instead of showing a result with a visible defect."
                    : "Built automatically from the best frames in both sequences. Final edge and matting quality gates are still in development."
            )
            .foregroundStyle(.white.opacity(0.72))
            .multilineTextAlignment(.center)
        }
    }

    private func resultPreview(
        _ image: UIImage,
        isLandscape: Bool,
        availableHeight: CGFloat
    ) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: isLandscape ? availableHeight * 0.58 : 520)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.38), radius: 12, y: 8)
            .accessibilityLabel("Combined group photo preview")
    }

    private var resultDetails: some View {
        Group {
            if let diagnostics = model.compositeOutput?.diagnostics {
                HStack(spacing: 18) {
                    Label("Best sequence frames selected", systemImage: "photo.stack")
                    Label("Processed on device", systemImage: "iphone")
                    #if DEBUG
                    Label(
                        "Photo \(diagnostics.baseSide == .one ? "1" : "2") base",
                        systemImage: "rectangle.2.swap"
                    )
                    #endif
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var resultActions: some View {
        HStack(spacing: 12) {
            Button {
                guard let image = model.compositeOutput?.image else { return }
                shareItems = [image]
                showShareSheet = true
            } label: {
                Label("Share result", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RaisedButtonStyle())

            Button("Retake Photo 2") { model.repeatSideTwo() }
                .buttonStyle(RaisedButtonStyle(tint: .gray))
        }
    }

    private var failureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(GroupCamTheme.warning)
            }
            Text("Keep the group in place, return the phone closer to Photo 1’s position, and leave a little room around both outside photographers.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
            HStack(spacing: 12) {
                Button("Retake Photo 2") { model.repeatSideTwo() }
                    .buttonStyle(RaisedButtonStyle())
                Button("Try Again") { model.retryComposite() }
                    .buttonStyle(RaisedButtonStyle(tint: .gray))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    private var sourcePreviews: some View {
        HStack(spacing: 10) {
            SourcePreview(title: "Photo 1", frame: model.pair.provisionalSideOne)
            SourcePreview(title: "Photo 2", frame: model.pair.provisionalSideTwo)
        }
    }

    private var sourcePackageSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DEBUG CAPTURE PACKAGE")
                .font(.caption.bold())
                .tracking(1.3)
                .foregroundStyle(GroupCamTheme.brass)
            Label(
                "\(model.pair.sideOneFrames.count + model.pair.sideTwoFrames.count) full-resolution source frames",
                systemImage: "photo.stack"
            )
            Label("Lens, exposure, white balance, focus and motion snapshots", systemImage: "waveform.path.ecg")
            Label("Protected app-private storage; excluded from backup", systemImage: "lock.shield")
            Text("Session \(model.pair.sessionID.uuidString)")
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.48))
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    private var corpusExportControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DEBUG CORPUS EXPORT")
                .font(.caption.bold())
                .tracking(1.3)
                .foregroundStyle(GroupCamTheme.brass)
            Text("Only export when every adult—and a guardian for every minor—signed the benchmark consent covering Mac transfer, named reviewers, no training, and the deletion deadline.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.74))
            Toggle("I have the required written consent", isOn: $model.corpusExportConsented)
                .tint(GroupCamTheme.safe)
            Button("Share source package") {
                guard model.prepareCorpusExport(), let archive = model.corpusArchiveURL else { return }
                shareItems = [archive]
                showShareSheet = true
            }
            .buttonStyle(RaisedButtonStyle(tint: .blue))
            .disabled(!model.canExportCorpus)
        }
        .padding(18)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    private var sessionActions: some View {
        Button("New session") { confirmStartOver = true }
            .buttonStyle(RaisedButtonStyle(tint: .gray))
    }
}

private struct SourcePreview: View {
    let title: String
    let frame: CapturedFrame?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image = frame?.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.white.opacity(0.08))
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.76))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let completion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            completion()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
