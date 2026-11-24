---
paths:
  - "**/*.swift"
---

# Swift の細則

AGENTS.md の「コーディング規約」の補足。Swift ファイルを編集するときに適用する。

## 並行性

- アプリターゲット（App/）は既定で MainActor。PDF 合成・画像のデコード・文字コード判定のような重い処理は非同期関数に切り出し、UI の更新は MainActor で行う。
- SurimonoCore の型は値型を中心にし、`Sendable` にする。WebKit・AppKit・PDFKit に触れる SurimonoRendering の型には `@MainActor` を明示する。
- `@unchecked Sendable` や `nonisolated(unsafe)` は、安全な理由をコメントで説明できる場合だけ使う。

## エラーと安全性

- 失敗しうる処理は意味のあるエラー型で `throws` する。UI ではユーザーに分かる文言に変換する。
- 強制アンラップ（`!`）と `try!` はテスト以外で使わない。
- ログは `print` ではなく `os.Logger`（subsystem: `app.surimono.Surimono`）を使う。文書の中身や個人情報をログに出さない。
- コードコメントとドキュメントコメントは英語で書く（テスト名は日本語）。

## ファイル

- ユーザーが開いたファイルとその周辺に書き込まない。一時ファイルは `FileManager.default.temporaryDirectory` 配下に作り、使い終わったら消す。
- アプリの設定は `AppPreferences`（`UserDefaults`）に保存する。ユーザー CSS とプリセットは `~/Library/Application Support/Surimono/` 配下の `Styles/` と `Presets/`（`UserLibrary`。Debug ビルドは `Surimono Dev/` 配下）。

## SwiftUI / AppKit

- 起動・文書の窓・メニューバーは AppKit が管理する。SwiftUI のビューは窓内にホストし、メニューバーの追加は `ViewerMainMenu` と `DocumentMenuDescriptor` を通す。
- 状態は `@Observable` で持つ（`ObservableObject` は使わない）。
- AppKit のビュー（PDFView、WKWebView）は `NSViewRepresentable` で包む。
- UI 文言は英語で書き、String Catalog（`App/Localizable.xcstrings`）に日本語訳を足す。
- 古い OS への対応は `if #available(macOS 26, *)` などの実行時の分岐で行う。CI とリリースは手元と同じ Xcode 27.2 で組むので、その SDK にある API を使ってよい。
