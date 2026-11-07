import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseFunctions
import GoogleSignIn

@main
struct DevTrackApp: App {
    @StateObject private var session: Session

    init() {
        if FirebaseApp.app() == nil && ProcessInfo.processInfo.environment["DEVTRACK_AUTH_EMULATOR"] == "1" {
            let options = FirebaseOptions(googleAppID: "1:123456789012:ios:1234567890abcdef", gcmSenderID: "123456789012")
            options.apiKey = "demo-key"
            options.projectID = "demo-devtrack"
            FirebaseApp.configure(options: options)
            Auth.auth().useEmulator(withHost: "127.0.0.1", port: 9099)
            Functions.functions(region: "asia-northeast1").useEmulator(withHost: "127.0.0.1", port: 5001)
        } else if FirebaseApp.app() == nil && Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
        }
        _session = StateObject(wrappedValue: Session(configured: FirebaseApp.app() != nil))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .onOpenURL { url in _ = GIDSignIn.sharedInstance.handle(url) }
        }
    }
}
