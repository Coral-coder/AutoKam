import SwiftUI

@main
struct AutoKamApp: App {
    @Environment(\.scenePhase) private var scenePhase

    #if os(iOS)
    @UIApplicationDelegateAdaptor(OrientationLock.self) private var orientationLock
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

#if os(iOS)
import UIKit

/// Lets the app lock the screen to portrait or landscape (or follow the phone).
final class OrientationLock: NSObject, UIApplicationDelegate {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.mask
    }

    static func apply(_ mask: UIInterfaceOrientationMask) {
        self.mask = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}
#endif
