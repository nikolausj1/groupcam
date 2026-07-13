import SwiftUI
import UIKit

struct RecorderReviewView: View {
    @ObservedObject var model: RecorderViewModel
    @State private var showShareSheet = false
    @State private var confirmStartOver = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text("CAPTURE RECORDED")
                        .font(.caption.bold())
                        .tracking(1.6)
                        .foregroundStyle(GroupCamTheme.safe)
                    Text("Both sides are ready")
                        .font(.largeTitle.bold())
                    Text("The compositor is the next milestone. For now, groupCam saved a protected source package with synchronized metadata.")
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    SourcePreview(title: "Photographer A", frame: model.pair.provisionalSideOne)
                    SourcePreview(title: "Photographer B", frame: model.pair.provisionalSideTwo)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("\(model.pair.sideOneFrames.count + model.pair.sideTwoFrames.count) full-resolution source frames", systemImage: "photo.stack")
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

                #if DEBUG
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
                        showShareSheet = model.prepareCorpusExport()
                    }
                    .buttonStyle(RaisedButtonStyle(tint: .blue))
                    .disabled(!model.canExportCorpus)
                }
                .padding(18)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                #endif

                HStack(spacing: 12) {
                    Button("Retake photo 2") { model.repeatSideTwo() }
                        .buttonStyle(RaisedButtonStyle(tint: .gray))
                    Button("New session") { confirmStartOver = true }
                        .buttonStyle(RaisedButtonStyle())
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showShareSheet) {
            if let archive = model.corpusArchiveURL {
                ShareSheet(items: [archive]) {
                    showShareSheet = false
                    model.finishCorpusExport()
                }
            }
        }
        .alert("Delete this recorded session?", isPresented: $confirmStartOver) {
            Button("Keep It", role: .cancel) {}
            Button("Delete and Continue", role: .destructive) { model.startOver() }
        } message: {
            Text("This removes the app-private source frames and metadata. Any files you already exported are outside groupCam’s control.")
        }
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
