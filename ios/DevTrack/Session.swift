import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import SwiftUI
import UIKit

@MainActor
final class Session: ObservableObject {
    @Published var user: User?
    @Published var error: String?
    let configured: Bool
    private var listener: AuthStateDidChangeListenerHandle?

    init(configured: Bool) {
        self.configured = configured
        if configured {
            listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
                Task { @MainActor in self?.user = user }
            }
        }
    }

    func email(_ email: String, password: String, register: Bool) async {
        guard configured else { return }
        do {
            if register { _ = try await Auth.auth().createUser(withEmail: email, password: password) }
            else { _ = try await Auth.auth().signIn(withEmail: email, password: password) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func google(link: Bool = false) async {
        do {
            guard configured, let clientID = FirebaseApp.app()?.options.clientID else {
                throw SessionError.missingGoogleConfiguration
            }
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow), let controller = window.rootViewController else {
                throw SessionError.noWindow
            }
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: controller)
            guard let idToken = result.user.idToken?.tokenString else { throw SessionError.missingToken }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            if link {
                guard let user = Auth.auth().currentUser else { throw SessionError.noUser }
                _ = try await user.link(with: credential)
            } else {
                _ = try await Auth.auth().signIn(with: credential)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func signOut() {
        do { try Auth.auth().signOut(); GIDSignIn.sharedInstance.signOut(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

enum SessionError: LocalizedError {
    case missingGoogleConfiguration, noWindow, missingToken, noUser
    var errorDescription: String? {
        switch self {
        case .missingGoogleConfiguration: return "Googleログインの設定がありません。"
        case .noWindow: return "ログイン画面を表示できません。"
        case .missingToken: return "Googleの認証情報を取得できませんでした。"
        case .noUser: return "先にログインしてください。"
        }
    }
}
