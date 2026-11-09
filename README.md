# DevTrack

開発時間を記録・同期・分析するiOS、macOS、Windows向けアプリの開発プロジェクトです。現在は開発中です。iOSではプロジェクト管理とタイマー、iOS・PCでは履歴の追加・編集・削除と終了済み履歴の同期を実装しています。PCの自動計測と分析は未実装です。

## 計画している機能

- iOSでの手動タイマー、プロジェクト管理、履歴、分析、ウィジェット
- macOS・Windowsでの対象作業の自動計測と放置時間の確認
- オフライン記録と復帰後のユーザー単位の同期

## 構成と技術

```mermaid
flowchart LR
  iOS[iOS: SwiftUI] --> I[(ローカル SQLite)]
  PC[macOS / Windows: Tauri + Rust] --> P[(ローカル SQLite)]
  I -->|同期キュー| Cloud[Firebase Auth / Firestore]
  P -->|同期キュー| Cloud
```

iOS・PCはSQLiteを記録の正本とし、終了済み履歴の変更と送信待ちを同時に保存します。再送の重複を防ぎ、別端末の変更が競合した場合は両方を端末に保持して選択できます。通信の再試行はアプリ使用中に行います。異なる作業間の重複区間の調整と分析は今後実装します。

自動計測は対象アプリの前面状態・操作状態・プロジェクト判定を組み合わせる予定です。ロックやスリープ中は計上せず、放置時間は確認待ちにします。ブラウザ情報は許可された対象に限定します。

Firebase UIDによる分離、Firestore Security Rules、OSの資格情報ストア、PCのOAuthとPKCEを前提に設計します。管理者秘密鍵をアプリに組み込みません。プロフィールと削除時のアクセス制御をエミュレータで検証しています。

## 開発と検証

現段階の基盤チェックはPython 3標準ライブラリのみで実行できます。

```sh
python3 -m unittest discover -s tests -v
python3 scripts/check_foundation.py
```

iOSのビルドにはXcode、デスクトップ開発にはRust、Node.jsおよび各OS向けTauri 2の前提環境が必要です。アプリのビルド手順は実装時に追加します。

仕様は [docs/SPEC.md](docs/SPEC.md)、構成は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)、計画と検証状況は [docs/DEVELOPMENT_PLAN.md](docs/DEVELOPMENT_PLAN.md) と [docs/PROGRESS.md](docs/PROGRESS.md) を参照してください。スクリーンショットは準備中です。AI支援を利用して開発しています。

## Firebaseエミュレータ検証

Node.js 24とJava 21を用意し、以下を実行します。実Firebaseプロジェクトではなく `demo-devtrack` とローカルエミュレータを使用します。

```sh
npm ci
npm run test:emulator
```

iOSシミュレータとmacOSで実Googleアカウントのログインを確認しています。iOS実機・Windowsは未検証です。Firestoreルールは本人のプロフィールと履歴に限定し、本番に適用済みです。完全なアカウント削除は未完成です。

認証と削除機能の開発状況、Firebaseのセットアップ状況は [docs/FIREBASE_SETUP.md](docs/FIREBASE_SETUP.md) を参照してください。iOS実機・WindowsでのGoogleログインの検証と、アカウントの完全削除は未完成です。
