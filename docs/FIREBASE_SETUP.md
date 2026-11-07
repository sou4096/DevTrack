# Firebaseと開発環境

Firebaseプロジェクト `devtrack-19cf3` にiOSアプリ `com.devtrack.app` とWebアプリ（PC用）を登録済み。設定ファイルは公開リポジトリに含めない。Authenticationの初期化とメール・Googleプロバイダの有効化を確認済み。PC向けGoogle OAuthクライアントは未設定。Firestore APIは未有効化で、データベースのリージョンは未決定。課金プランの変更は行っていない。

## iOS

XcodeとXcodeGenが必要。Firebaseコンソールでアプリ設定を取得し、`ios/DevTrack/GoogleService-Info.plist` に配置してから以下を実行する。Googleプロバイダ有効化後のplistに `CLIENT_ID` と `REVERSED_CLIENT_ID` が含まれる必要がある。`python3 configure.py` で無視対象のローカル設定を生成する。Firebase認証を利用するには実プロジェクトで該当プロバイダを有効にする。

```sh
cd ios
python3 configure.py
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DevTrack.xcodeproj -scheme DevTrack -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

エミュレータ専用の実行時環境変数 `DEVTRACK_AUTH_EMULATOR=1` は `demo-devtrack` を使用し、localhostのAuthenticationエミュレータに接続する。実機のlocalhostはMacではないため、そのまま実機に使わない。Googleの実ログイン・連携は未検証。

## PC

Node.js、Rust、Tauriの前提環境が必要。`desktop/.env.local` に `VITE_FIREBASE_API_KEY` と `VITE_FIREBASE_PROJECT_ID` を設定してから以下を実行する。Firebase設定ファイルをGitへ追加しない。WebView内の認証情報はメモリのみに保持し、アプリ終了時に消える。OS資格情報ストアへの永続化は未実装。

```sh
cd desktop
npm ci
npm run tauri -- build --debug
```

開発時に `VITE_AUTH_EMULATOR=1 npm run dev` とすると、ローカルのAuthenticationエミュレータを使用する。リリースビルドではエミュレータ設定を無効にする。Googleログインには外部ブラウザ、PKCE、ループバック受信の実装とGoogle CloudのデスクトップOAuthクライアントが必要で、未実装。

## 削除

`server/deletion.js` は順序と失敗時の振る舞いだけを検証する未接続の設計コード。実サーバー、アクセス停止マーカーを強制するルール、永続的な再試行、Firestore以外のデータと各端末のローカルデータ削除、Google再認証は未実装。アプリの削除操作は有効化しない。将来の削除処理は、最近の認証確認後に書き込みを停止し、全保存先を再帰的に削除してからAuthユーザーを削除する。停止マーカー・再試行記録の保持期間とプライバシーも設計する。
