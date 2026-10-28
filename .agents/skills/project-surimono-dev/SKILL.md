---
name: project-surimono-dev
description: Builds, runs, tests, and visually checks the Surimono macOS app from the command line. Use when building or launching Surimono, running its lint or tests, opening sample documents, or verifying a UI change with screenshots. Not for cutting releases (use project-surimono-release).
---

# project-surimono-dev

Surimono の開発ループ（ビルド → 起動 → テスト → 目視確認）を回す手順。

## 手順

1. 変更範囲に応じて検証する。
   - SurimonoKit だけを変えた: `make lint && make test-kit`
   - アプリ（`App/`、`Configs/`、Xcode プロジェクト）を変えた: `make lint && make build && make test-app`
   - 迷ったら `make lint && make test`
2. 起動して確認する: `make run FILE=Samples/sample.md`
   - サンプルは `Samples/` にある（sample.md / sample.org / sample.txt / sample-sjis.txt（Shift_JIS）/ sample.html（ノイズ入り）/ sample.csv / booklet-demo.md（標準テーマの A4 で 38 ページ。冊子の確認用））。PDF と画像は手元の任意のファイルでよい。
3. UI を変えたら目視で確認する。見ずに完了としない。
   - **開発用スナップショット（推奨。画面収録の許可が不要）**: DEBUG ビルドは起動引数を受け取り、最初の文書ウィンドウの描画が終わると、そのウィンドウを ScreenCaptureKit で PNG に保存する。

     ```bash
     make build
     APP="$PWD/build/DerivedData/Build/Products/Debug/Surimono.app"
     open -n -W -a "$APP" "$PWD/Samples/booklet-demo.md" --args \
       -SurimonoSnapshotPath /tmp/surimono-booklet.png -SurimonoSnapshotQuit YES \
       -SurimonoAppearance light -SurimonoLayout a3BookletA4 -SurimonoPreviewMode sheets
     ```

     引数: `-SurimonoSnapshotPath <PNG の絶対パス>`（開いている文書は上書きできない）、`-SurimonoSnapshotQuit YES`（保存後に終了）、`-SurimonoAppearance light|dark`、`-SurimonoLayout <PrintLayout の id>`（a4Single / a4Duplex / a3BookletA4 / a4BookletA5 / a3TwoUp）、`-SurimonoPreviewMode sheets|pages`。保存先のディレクトリは先に作っておく。Release ビルドには含まれない。
   - 操作まで確かめたい場合: Claude Code なら computer-use の `request_access`（アプリ名 Surimono）→ `app_screenshot`（ユーザーが許可しなければ使わない）。それ以外は `screencapture -x -o -l "$(swift .agents/skills/project-surimono-dev/scripts/window-id.swift)" /tmp/surimono.png`（実行するターミナルに画面収録の許可が必要）。
   - ライト / ダークの両方と、空・読み込み中・エラー・長い文書の状態を見る。冊子は用紙表示で面付け（1 枚目の表が [最終ページ | 1]）も確かめる。
4. 終わったら起動したアプリを終了する: `osascript -e 'quit app "Surimono"'`。

## つまずきやすい点

- `make` が失敗したら、まず `xcodebuild -version` と `swift --version` で Xcode を確かめる（CI は Xcode 26.6、ローカルは 27 系を想定）。
- パッケージ解決のエラーは `rm -rf build/DerivedData Packages/SurimonoKit/.build` の後に再実行する。
- WebKit を使うテストが時々落ちるときは、単発の成否で判断せず、複数回実行して失敗率を見る。
- ファイルを追加しても `Surimono.xcodeproj` の編集は不要（synchronized folder）。ビルド設定は `Configs/*.xcconfig` で変える。
