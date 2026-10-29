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
   - サンプルは `Samples/` にある（sample.md / sample.org / sample.txt / sample-sjis.txt（Shift_JIS）/ sample.html（ノイズ入り）/ sample.csv / booklet-demo.md（標準テーマの A4 で 38 ページ。冊子の確認用））。PDF・画像・画像の ZIP は手元の任意のファイルでよい（ZIP は `ditto -c -k --keepParent <フォルダ> <名前>.zip` で作れる）。
3. UI を変えたら目視で確認する。見ずに完了としない。
   - **開発用スナップショット（推奨。画面収録の許可が不要）**: DEBUG ビルドは起動引数を受け取り、最初の文書ウィンドウの描画が終わると、そのウィンドウと近くのポップオーバーなどの子ウィンドウを ScreenCaptureKit で PNG に保存する。

     ```bash
     make build
     APP="$PWD/build/DerivedData/Build/Products/Debug/Surimono.app"
     open -n -W -a "$APP" "$PWD/Samples/booklet-demo.md" --args \
       -SurimonoSnapshotPath /tmp/surimono-view.png -SurimonoSnapshotQuit YES -ApplePersistenceIgnoreState YES \
       -SurimonoAppearance light -SurimonoMenu full -SurimonoViewLayout spread
     ```

     引数:
     - 撮影: `-SurimonoSnapshotPath <PNG の絶対パス>`（開いている文書は上書きできない）、`-SurimonoSnapshotQuit YES`（保存後に終了）。保存先のディレクトリは先に作っておく
     - 外観: `-SurimonoAppearance light|dark`（アプリ全体の外観を固定する。アプリ自体に外観の切替はない）
     - 印刷: `-SurimonoLayout <PrintLayout の id>`（a4Single / a4Duplex / a3BookletA4 / a4BookletA5 / a3TwoUp）
     - 表示: `-SurimonoViewLayout spread|single`、`-SurimonoTransition scroll|instant|slide|fade|pageCurl`、`-SurimonoCoverAlone YES`、`-SurimonoRightToLeft YES`、`-SurimonoZoom <倍率>`
     - メニューと窓: `-SurimonoMenu compact|full|pinned`（段階 1 / 段階 2 / 固定）、`-SurimonoPopover view`（表示のオプション）、`-SurimonoAlwaysOnTop YES`、`-SurimonoSelectText YES`（文字を選択）、`-SurimonoDrawer YES`（画像の束のサムネイル）
     - 印刷モード: `-SurimonoMode print`（刷り台で撮る）、`-SurimonoMode roundtrip`（刷り台に入って表示モードへ戻ったところを撮る）、`-SurimonoFold YES`（折ってみる）
     - スマート削除（HTML）: `-SurimonoSmartRemoval on|review`（オン / 確かめるパネルを開く）
     - ページ送り: `-SurimonoTurn forward|back`（アニメーションを 10 倍遅くして 1 ページ送り、途中で撮る。送りの向きの確認用）
     - ページ: `-SurimonoPage <n>`（撮る前に n ページ目へ移る。`-SurimonoMode roundtrip` と合わせると、印刷モードから戻っても同じページかを見られる）
     - Release ビルドには含まれない。表示の引数で設定を変えると、その文書の設定として `~/Library/Application Support/Surimono/DocumentSettings/` に保存される（次に開くと「戻しました」が出る）。確認用のファイルの記録は確認後に消す
     - 画像の束を撮るときは、`open` に画像を複数まとめて渡す（例: `open -n -W -a "$APP" a.png b.jpg c.heic --args …`）。束のウィンドウが撮られる。
     - 前回のウィンドウの復元が混ざらないよう、確認用の起動には `-ApplePersistenceIgnoreState YES` も付けるとよい（`pkill` などで落とすと次の起動で文書が復元される）。
   - **開き方の確認（ウィンドウの数と題名）**: `swift .agents/skills/project-surimono-dev/scripts/list-windows.swift` が開発版の画面上のウィンドウを前面から順に、レイヤー・位置・大きさ・題名つきで出す（題名は画面収録の許可がないと空になる。レイヤー 8 はアラートなどのモーダル。数えるのは名前が Surimono Dev の全プロセスの画面上のウィンドウで、公開版と最小化したものは含まない。一覧を取れなければ終了コード 1）。Finder や Dock からの開き方は `open -a "$APP" <ファイル…>` で再現し、AGENTS.md の「ウィンドウとファイルの開き方」の規則どおりの数と題名になるかを見る。
   - 操作まで確かめたい場合: Claude Code なら computer-use の `request_access`（開発版のバンドル ID `io.github.phyten.Surimono.debug`）→ `app_screenshot`（ユーザーが許可しなければ使わない）。それ以外は `screencapture -x -o -l "$(swift .agents/skills/project-surimono-dev/scripts/window-id.swift)" /tmp/surimono.png`（実行するターミナルに画面収録の許可が必要）。
   - ライト / ダークの両方と、空・読み込み中・エラー・長い文書の状態を見る。表示モードはメニューの段階（乗せただけ / 上部 / 固定）と、見開き・単ページを見る。冊子は書き出した PDF か印刷パネルのプレビューで面付け（1 枚目の表が [最終ページ | 1]）も確かめる。
4. 終わったら起動したアプリを終了する: `osascript -e 'quit app id "io.github.phyten.Surimono.debug"'`（名前で指定すると、入れてある公開版を終了してしまう）。

## つまずきやすい点

- `make` が失敗したら、まず `xcodebuild -version` と `swift --version` で Xcode を確かめる（CI は Xcode 26.6、ローカルは 27 系を想定）。
- パッケージ解決のエラーは `rm -rf build/DerivedData Packages/SurimonoKit/.build` の後に再実行する。
- WebKit を使うテストが時々落ちるときは、単発の成否で判断せず、複数回実行して失敗率を見る。
- ファイルを追加しても `Surimono.xcodeproj` の編集は不要（synchronized folder）。ビルド設定は `Configs/*.xcconfig` で変える。
