import SwiftUI

@main
struct groupCamApp: App {
    @StateObject private var model = RecorderViewModel()

    var body: some Scene {
        WindowGroup {
            RecorderFlowView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}

