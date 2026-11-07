import SwiftUI

struct ContentView: View {
    @ObservedObject var session: Session
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var confirmDelete = false
    @State private var deleteWithGoogle = false
    private var deletionEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DEVTRACK_AUTH_EMULATOR"] == "1" &&
            ProcessInfo.processInfo.environment["DEVTRACK_ACCOUNT_DELETION_TEST"] == "1" { return true }
        #endif
        return (Bundle.main.object(forInfoDictionaryKey: "DevTrackAccountDeletionEnabled") as? String) == "YES"
    }

    var body: some View {
        NavigationStack {
            Form {
                if !session.configured {
                    Text("Firebaseの設定がありません。開発手順を確認してください。")
                } else if let user = session.user {
                    Section("アカウント") {
                        Text(user.email ?? "ログイン済み")
                        Button("Googleアカウントを連携") { run { await session.google(link: true) } }
                        Button("ログアウト") { session.signOut() }
                        if deletionEnabled {
                            if user.providerData.contains(where: { $0.providerID == "password" }) {
                                SecureField("削除確認用パスワード", text: $password)
                                Button("パスワードで再認証して削除", role: .destructive) { deleteWithGoogle = false; confirmDelete = true }
                            }
                            if user.providerData.contains(where: { $0.providerID == "google.com" }) {
                                Button("Googleで再認証して削除", role: .destructive) { deleteWithGoogle = true; confirmDelete = true }
                            }
                        } else {
                            Text("アカウントの完全削除は準備中です。").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section("ログイン") {
                        TextField("メールアドレス", text: $email)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("パスワード", text: $password)
                        Button("ログイン") { run { await session.email(email, password: password, register: false) } }
                        Button("アカウント作成") { run { await session.email(email, password: password, register: true) } }
                        Button("Googleでログイン") { run { await session.google() } }
                    }
                }
                if let error = session.error { Text(error).foregroundStyle(.red) }
                if let notice = session.notice { Text(notice) }
                if busy { ProgressView() }
            }
            .disabled(busy)
            .navigationTitle("DevTrack")
            .confirmationDialog("アカウントとクラウド上のデータを削除します。この操作は取り消せません。", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("削除する", role: .destructive) {
                    let enteredPassword = password
                    password = ""
                    run { await session.requestDeletion(password: enteredPassword, useGoogle: deleteWithGoogle) }
                }
            }
        }
    }

    private func run(_ operation: @escaping () async -> Void) {
        busy = true
        Task { await operation(); busy = false }
    }
}
