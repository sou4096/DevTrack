# Firebaseと開発環境

プロジェクト `devtrack-19cf3` にiOSアプリ `com.devtrack.app` とPC用Webアプリを登録済み。メール・Googleプロバイダを有効化し、メール認証を実環境で検証済み。設定ファイルは公開リポジトリに含めない。Firestoreの標準データベース `(default)` は東京リージョン `asia-northeast1` に作成済みで、無料枠対象。Firestore Rulesを本番に適用済み。課金は無効で、ユーザーの意向により今回はBlazeプランへ変更しない。Cloud Functionsの本番デプロイにはBlazeプランが必要。

## iOS

XcodeとXcodeGenが必要。Firebaseの設定 `GoogleService-Info.plist` を `ios/DevTrack/` に置き、以下を実行する。Googleプロバイダ有効化後の設定に `CLIENT_ID` と `REVERSED_CLIENT_ID` が必要。`configure.py` はローカル専用設定を生成する。

```sh
cd ios
python3 configure.py
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DevTrack.xcodeproj -scheme DevTrack -sdk iphonesimulator CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

実GoogleログインはiOSシミュレータでアカウント表示まで確認済み。実機は未検証。削除UIは `DEVTRACK_ACCOUNT_DELETION_ENABLED=YES` のビルド設定で有効にできるが、本番サービスの設定・運用検証が完了するまで無効とする。シミュレータUIテストは `DEVTRACK_AUTH_EMULATOR=1` と `DEVTRACK_ACCOUNT_DELETION_TEST=1` でエミュレータのみを使用する。

## PC

Node.js、Rust、Tauriが必要。`desktop/.env.local` に `VITE_FIREBASE_API_KEY` と `VITE_FIREBASE_PROJECT_ID` を設定。Google Cloudのデスクトップ用OAuthクライアントのJSONを `desktop/google-oauth-client.json` に置き `python3 desktop/run-desktop.py` で起動する。設定ファイルはGit管理対象外。Google認証は外部ブラウザ、ランダムなローカルポート、state、PKCEを使用する。macOSでは実Googleログイン後にメールアドレスがアプリへ表示されたとユーザーが確認済み。Windowsは未検証。

認証状態はメモリのみに保持する。OS資格情報ストアへの永続化は未実装のため、PCアプリの再起動後は再ログインが必要で、オフラインではログインできない。ログイン中に作った履歴と送信待ちはアカウント別SQLiteに残り、同じアカウントで次にログインすると再送する。エミュレータ用と本番用の保存場所も分離する。削除UIはビルド環境変数 `VITE_ENABLE_DELETION=1` で有効にできるが、本番ではサービスの設定・運用検証が完了するまで無効にする。エミュレータには開発時の `VITE_AUTH_EMULATOR=1` で接続する。

## 削除の実装と未完了事項

直近5分の認証を検証する呼び出し可能関数が、本人のUIDだけを用いて削除要求を作る。Firestore Rulesは要求が存在するアカウントのアクセスを拒否する。再試行可能な関数がAuthユーザーを無効化し、`users/{uid}` とサブコレクションを再帰削除した後、Authユーザーを削除する。UIは再認証と明示的な確認の後に要求を送信し、受理と削除完了を区別する。

Firestoreにはプロフィールに加え、本人の `history` と不変の `historyOps` を保存する。削除関数が両コレクションを再帰削除することはエミュレータで検証済みだが、関数は本番未デプロイ。各端末のローカルデータと端末間の削除伝播、失敗後の運用上の再実行、完了通知、削除マーカーの保持期限と消去は未完成。削除済みユーザーの古いIDトークンによるアクセスを防ぐため、現在はUIDをキーとするマーカーを残す。完全な削除を保証できないため削除UIは初期状態で無効。Firestore Rulesは本番に適用済み。

履歴同期はiOS・PCの終了済み作業区間に対応。アプリの使用中は変更直後と約60秒ごと、前面復帰時に同期を試み、失敗した変更はSQLiteに残す。Firestoreの読み書きと操作履歴には利用量が発生する。課金プランは変更していない。iOS実機・Windowsでの検証とバックグラウンド同期は未完了。

```sh
npm ci
npm ci --prefix functions
npm run test:emulator
npm run test:deletion
```
