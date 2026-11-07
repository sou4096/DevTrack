import SwiftUI

struct ContentView: View {
    @ObservedObject var session: Session
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false

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
                        Text("アカウントの完全削除は準備中です。")
                            .foregroundStyle(.secondary)
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
                if busy { ProgressView() }
            }
            .disabled(busy)
            .navigationTitle("DevTrack")
        }
    }

    private func run(_ operation: @escaping () async -> Void) {
        busy = true
        Task { await operation(); busy = false }
    }
}
