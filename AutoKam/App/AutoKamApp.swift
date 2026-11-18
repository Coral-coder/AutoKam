import SwiftUI

@main
struct AutoKamApp: App {
    @Environment(\.scenePhase) private var scenePhase

    #if os(iOS)
    @StateObject private var model = CameraAppModel()

    var body: some Scene {
        WindowGroup {
            CameraScreen(model: model, link: model.link, store: model.store)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.enteredBackground() }
                }
        }
    }
    #else
    @StateObject private var model = ReceiverModel()

    var body: some Scene {
        WindowGroup("AutoKam") {
            ReceiverScreen(model: model)
                .frame(minWidth: 900, minHeight: 580)
        }
        .defaultSize(width: 1180, height: 720)
    }
    #endif
}
