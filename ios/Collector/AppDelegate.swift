import UIKit
import SwiftUI

// @Environment(\.scenePhase) only tracks foreground/background when the app uses the
// SwiftUI App/Scene lifecycle. This app hosts SwiftUI manually via UIHostingController,
// so scenePhase never updates; use this instead, driven by the scene delegate below.
final class AppActivity:ObservableObject {
    static let shared=AppActivity()
    @Published var active=true
}

@main class AppDelegate:UIResponder,UIApplicationDelegate {
    func application(_ application:UIApplication,configurationForConnecting session:UISceneSession,options:UIScene.ConnectionOptions)->UISceneConfiguration {
        let config=UISceneConfiguration(name:"Collector",sessionRole:session.role)
        config.delegateClass=CollectorSceneDelegate.self
        return config
    }
}

class CollectorSceneDelegate:UIResponder,UIWindowSceneDelegate {
    var window:UIWindow?
    private var privacyCover:UIView?
    func scene(_ scene:UIScene,willConnectTo session:UISceneSession,options:UIScene.ConnectionOptions) {
        guard let scene=scene as? UIWindowScene else {return}
        let window=UIWindow(windowScene:scene)
        window.rootViewController=UIHostingController(rootView:CollectorView())
        window.makeKeyAndVisible();self.window=window
    }
    func sceneWillResignActive(_ scene:UIScene) {
        AppActivity.shared.active=false
        guard let window,privacyCover==nil else {return}
        let cover=UIView(frame:window.bounds);cover.backgroundColor = .black;cover.autoresizingMask=[.flexibleWidth,.flexibleHeight]
        window.addSubview(cover);privacyCover=cover
    }
    func sceneDidBecomeActive(_ scene:UIScene) {AppActivity.shared.active=true;privacyCover?.removeFromSuperview();privacyCover=nil}
}
