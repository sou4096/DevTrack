# 進捗・再開情報

更新: 2026-11-08（日本時間）

- Phase 0: 基盤文書・テスト・CI定義あり。Xcode 26.6は `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` で利用可能。Node.js 24とJava 21をHomebrewで導入。Rust、Windows開発環境は未確認。GitHub Actionsの実行状況は別途確認する。
- Phase 1: Firebase JavaScript SDKの認証アダプターとプロフィール用Firestore Rulesを試作。エミュレータでメール認証・Google模擬資格情報による連携・ユーザー分離・検証ルールをテスト。iOS・PCアプリへの組み込み、実Googleログイン、実Firebase設定、完全なアカウント削除は未実装。Rulesは実プロジェクト未デプロイ。
- Phase 2〜8: 未着手。同期・タイマー・自動計測は未実装。
- 検証環境: `PATH="/opt/homebrew/opt/node@24/bin:/opt/homebrew/opt/openjdk@21/bin:$PATH" JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" npm run test:emulator`。基盤検証は `python3 -m unittest discover -s tests -v` と `python3 scripts/check_foundation.py`。
- npm監査: 開発用依存関係などに中程度の指摘が残る。Firestoreの古いgRPC依存は一時的に上書きしており、SDK更新時に再評価する。
- 次: CI結果を確認、iOSアプリと実Firebaseの登録・認証設定を行い、実端末とGoogle認証を検証する。モデル・同期プロトコルに合わせてルールを拡張し、完全削除フローを設計する。

## 2026-11-08 続き

- Firebase CLIログイン確認。`devtrack-19cf3` にiOS `com.devtrack.app` とPC用Webアプリを登録し、設定をローカルに取得。Authenticationはコンソールで初期化され、メール・Google両プロバイダ有効を確認。実Firebaseで一時アカウントのメール登録・ログイン・削除に成功。Firestore APIは未有効化。
- iOS: SwiftUI認証画面、メール登録・ログイン、Googleログイン・連携のコードを追加。シミュレータ向けビルド成功。実Google認証は未検証。署名されたシミュレータでメール登録・ログアウトのUIテスト1件成功。
- PC: Tauri試作とメール認証画面を追加し、macOS向けデバッグビルド成功。ブラウザでエミュレータへの登録とログアウトを確認。Tauri内での操作、Windows、Google OAuth/PKCE、安全な永続保存は未検証・未実装。
- 削除: 認証アカウントのみを削除する既存APIを除去。サーバー側の削除手順の純粋なロジックと単体テスト3件を追加したが、実サービス・再試行・データ全消去には未接続のため機能未完成。
- XcodeGenとRustをHomebrewで導入。iOSプロジェクトは `ios/project.yml` から生成する。詳細は `docs/FIREBASE_SETUP.md`。

- 検証結果: 基盤テスト1件、Auth・Rules・削除ロジックのエミュレータテスト9件成功。PC画面はブラウザでエミュレータに接続して登録・ログアウト成功。iOS UIテストは `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` で成功。Googleの実ログイン、Tauriウィンドウ内操作、Windowsと完全削除は未検証。

## 2026-11-08 Google認証・削除作業

- PC: 外部ブラウザ、PKCEとランダムなstate、ループバック受信、FirebaseへのGoogle認証・明示的な連携を実装。RFC例と不正な応答を拒否するRustテスト2件成功。Google CloudのデスクトップOAuthクライアント設定と実Googleログイン、Windows実機は未検証。
- iOS: Googleログイン・連携は実装済み、実Googleアカウントでは未検証。シミュレータでメール登録・ログアウトおよびメール再認証後の削除要求のUIテスト計2件成功。
- 削除: 認証時刻検証、Firestore削除マーカーによるアクセス拒否、再試行可能な再帰削除・Auth削除を実装。エミュレータで未認証拒否、ユーザー分離、入れ子の削除とAuth削除を検証。PC画面の削除操作をブラウザ＋エミュレータで検証。削除完了通知、各端末への削除伝播、全保存先・マーカーの保持ポリシーなど未完成のため本番UIは無効。Cloud Functionsは未デプロイで課金設定も無効。
- FirestoreのリージョンとCloud Functionsの課金プランについて回答待ち。Firestore Rulesには削除マーカーによるアクセス拒否を追加し、実環境未デプロイ。
- ローカル: Firebaseルール・認証・削除ロジック10件、削除関数の統合テスト1件、Rust 2件、iOS UI 2件成功。CI定義に関数の統合検証、macOSのRustテスト、iOSシミュレータテストを追加。

- Firestore APIを有効化し、データベースが未作成であることを確認。作成リージョンについて回答待ち。
