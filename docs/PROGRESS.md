# 進捗・再開情報

更新: 2026-11-08（日本時間）

- Phase 0: 基盤文書・テスト・CI定義あり。Xcode 26.6は `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` で利用可能。Node.js 24とJava 21をHomebrewで導入。Rust、Windows開発環境は未確認。GitHub Actionsの実行状況は別途確認する。
- Phase 1: Firebase JavaScript SDKの認証アダプターとプロフィール用Firestore Rulesを試作。エミュレータでメール認証・Google模擬資格情報による連携・ユーザー分離・検証ルールをテスト。iOS・PCアプリへの組み込み、実Googleログイン、実Firebase設定、完全なアカウント削除は未実装。Rulesは実プロジェクト未デプロイ。
- Phase 2〜8: 未着手。同期・タイマー・自動計測は未実装。
- 検証環境: `PATH="/opt/homebrew/opt/node@24/bin:/opt/homebrew/opt/openjdk@21/bin:$PATH" JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" npm run test:emulator`。基盤検証は `python3 -m unittest discover -s tests -v` と `python3 scripts/check_foundation.py`。
- npm監査: 開発用依存関係などに中程度の指摘が残る。Firestoreの古いgRPC依存は一時的に上書きしており、SDK更新時に再評価する。
- 次: CI結果を確認、iOSアプリと実Firebaseの登録・認証設定を行い、実端末とGoogle認証を検証する。モデル・同期プロトコルに合わせてルールを拡張し、完全削除フローを設計する。
