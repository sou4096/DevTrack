import FirebaseAuth
import FirebaseCore
import FirebaseFunctions
import GoogleSignIn
import SwiftUI
import UIKit

@MainActor
final class Session: ObservableObject {
    @Published var user: User?
    @Published var error: String?
    @Published var notice: String?
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

    func requestDeletion(password: String?, useGoogle: Bool) async {
        do {
            guard let current = Auth.auth().currentUser else { throw SessionError.noUser }
            let credential: AuthCredential
            if useGoogle {
                guard let clientID = FirebaseApp.app()?.options.clientID else { throw SessionError.missingGoogleConfiguration }
                guard let controller = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { throw SessionError.noWindow }
                GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: controller)
                guard let token = result.user.idToken?.tokenString else { throw SessionError.missingToken }
                credential = GoogleAuthProvider.credential(withIDToken: token, accessToken: result.user.accessToken.tokenString)
            } else {
                guard let email = current.email, let password, !password.isEmpty else { throw SessionError.passwordRequired }
                credential = EmailAuthProvider.credential(withEmail: email, password: password)
            }
            _ = try await current.reauthenticate(with: credential)
            _ = try await current.getIDToken(forcingRefresh: true)
            guard Auth.auth().currentUser?.uid == current.uid else { throw SessionError.noUser }
            _ = try await Functions.functions(region: "asia-northeast1").httpsCallable("requestAccountDeletion").call()
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
            notice = "削除を受け付けました。クラウド上のデータ削除はバックグラウンドで進行します。"
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

enum SessionError: LocalizedError {
    case missingGoogleConfiguration, noWindow, missingToken, noUser, passwordRequired
    var errorDescription: String? {
        switch self {
        case .missingGoogleConfiguration: return "Googleログインの設定がありません。"
        case .noWindow: return "ログイン画面を表示できません。"
        case .missingToken: return "Googleの認証情報を取得できませんでした。"
        case .noUser: return "先にログインしてください。"
        case .passwordRequired: return "再認証のためパスワードを入力してください。"
        }
    }
}
