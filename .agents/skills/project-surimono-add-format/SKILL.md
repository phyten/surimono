---
name: project-surimono-add-format
description: Adds support for a new document format to Surimono end to end, from type detection and Info.plist registration to conversion, tests, and samples. Use when asked to open, preview, or print a file type Surimono does not support yet (for example TeX or reStructuredText). Not for print layout changes (use project-surimono-print-layout).
---

# project-surimono-add-format

新しいファイル形式を「開ける・見える・刷れる」状態にする手順。

## 手順

1. 紙にする方式を決める。
   - テキスト系 → HTML 断片に変換して Web 系のパイプラインに乗せる（印刷テーマが効く）。
   - 固定レイアウト系 → SurimonoRendering で PDF ページを直接作る。
2. テストを先に書く（Swift Testing、日本語のテスト名）。形式の判定と変換結果を確かめる。入力はできるだけテスト内の文字列で用意し、ファイルの fixture が必要なら `.claude/rules/tests.md` の置き場所と読み方に従う（SurimonoKit は Package.swift の testTarget に resources の登録が必要）。
3. `SurimonoCore` の `DocumentFormat` に case を足し、拡張子・UTType との対応と表示名を追加する。
4. 変換を実装する。テキスト系は SurimonoCore に `<形式名>Converter` を足し、HTML 断片を返す。HTML の特殊文字のエスケープと、文字コード判定（`TextDecoding`）を忘れない。
5. `DocumentRenderer`（SurimonoRendering）の形式ごとの分岐に接続し、印刷テーマの対象かどうかを `DocumentFormat` のフラグ（`usesPrintTheme` など）で決める。テキスト系は JavaScript を無効にして `WebPaginator` に渡す。
6. アプリに登録する。
   - `Configs/Info.plist` の `CFBundleDocumentTypes`（役割 Viewer、`LSHandlerRank` は Alternate）と、システムに型がなければ `UTImportedTypeDeclarations`。コード側の `UTType(importedAs:)` と識別子をそろえる。
   - `App/SurimonoDocument.swift` の `readableContentTypes` に型を足す（Info.plist とは別に列挙している）。
   - `AppTests/SurimonoDocumentTests.swift` の登録の整合性テスト（Info.plist の文書形式・UTI 宣言と `readableContentTypes` の一致）が通ることを確かめる。
7. `Samples/` にサンプルを足し、README.md と README.ja.md の対応形式の表を更新する。
8. 検証する: `make lint && make test`、`make run FILE=Samples/<サンプル>` で表示・印刷プレビュー・PDF 書き出しを確認する（手順は `project-surimono-dev`）。

## 判断基準

- 外部ライブラリが必要なら、ライセンス（MIT と両立するか）と保守状況を確認し、PR に理由を書く。構文が小さければ自前のパーサで足りることが多い。
- 既存アプリから「既定のアプリ」を奪わない（`LSHandlerRank` は Alternate）。
- 開いたファイルを書き換えない。変換の中間ファイルは一時ディレクトリに作り、使い終わったら消す。
