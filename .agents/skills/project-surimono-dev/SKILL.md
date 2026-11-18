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
   - `make test` は `test-kit` のあとに `test-app` を順に走らせる（同時に走らせると、待ち時間に頼るホスト付きテストが落ちる）。一方だけなら `make test-kit` / `make test-app`、Kit の片方だけなら `make test-core` / `make test-rendering`。
   - Rendering のテストは並列にしない（`--no-parallel`）。WebKit と静的な状態（`WebPaginator.clearBackground` など）を共有していて、手元で並列に走らせると毎回 20 件ほど落ちる。
2. 起動して確認する: `make run FILE=Samples/sample.md`
   - Debug ビルドは公開版と別のアプリ「Surimono Dev」（バンドル ID `io.github.phyten.Surimono.debug`、保存先 `~/Library/Application Support/Surimono Dev/`）として動き、入れてある公開版と同時に起動できる。メニューバーの名前だけは Surimono のまま。
   - サンプルは `Samples/` にある（sample.md / sample.org / sample.txt / sample-sjis.txt（Shift_JIS）/ sample.html（ノイズ入り）/ sample.csv / sample.ipynb（保存済みの出力つきのノート）/ sample.dot（Graphviz）/ sample.puml（PlantUML。図が 2 つ） / sample.adoc（AsciiDoc）/ booklet-demo.md（標準テーマの A4 で 38 ページ。冊子の確認用）/ callouts.md（すべての種類の囲み））。PDF・画像・画像の ZIP は手元の任意のファイルでよい（ZIP は `ditto -c -k --keepParent <フォルダ> <名前>.zip` で作れる）。
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
     - 外観: `-SurimonoAppearance light|dark|system`（その起動だけアプリ全体の外観を決める。設定の「外観」より優先し、設定には書かない）
     - 設定の窓: `-SurimonoSettings <SettingsSection の case 名>`（general・view・toolbarArrangement・pageNumbers・printing・settingSets・styles・html。文書の描画のあと設定の窓をその区分で開き、文書の窓を隠して設定の窓を撮る）。言語は `-AppleLanguages "(de)"` などで選ぶ。`-SurimonoSettingsSize 820x540` で設定の窓の中身の大きさ（最小は 820×540）
     - ツールバーの配置: `-SurimonoBandArrangement printBottom|reordered|sparse|editor|editorReading|unreadable|repaired`（メモリだけの配置セット。`editor` は標準を、`editorReading` は保存したセットを使用中にする。`unreadable` は読めない保存データ、`repaired` は読み込みで記録を外し組み方を標準に戻したデータ。どれも保存を拒むので実際の設定は変わらない）、`-SurimonoArrangementEditor <状態,…>`（`top`・`draft`（区切り線を含む未保存の変更）・`select:<部品の ID>`・`drop:<領域>:<位置>`（ドラッグ中の差し込み位置）・`refused`（印刷を外そうとして断られた）・`unsaved`（未保存の確認）・`delete`・`new`（シート）・`conflict`（外で保存が変わった競合）・`quit`（設定が出てから run loop のタイマーで `NSApp.terminate` を呼び、終了の確認を出す。撮ったあとは取り消して破棄してから終了する））。`-SurimonoArrangementProbe <パス>` は、実際の設定の窓のレスポンダチェーンと、取り消しが編集画面の履歴に行き窓の履歴が残るかを書く。設定の窓で編集した配置を実際に保存しない（開発版の設定に残る）
     - 印刷: `-SurimonoLayout <PrintLayout の id>`（a4Single / a4Duplex / a3BookletA4 / a4BookletA5 / a3TwoUp / b5Single / b5Duplex / b4BookletB5 / b5BookletB6 / b4TwoUp）
     - 手動両面の用紙戻しシート: `-SurimonoManualDuplexSheet YES`、`-SurimonoManualDuplexSheets 3`、`-SurimonoManualDuplexReverseBacks YES|NO`、`-SurimonoManualDuplexRotateBacks YES|NO`。既存の `-SurimonoLayout`・言語・外観・撮影先と併用する。合成プリンター・固定した用紙・メモリ内の手動補正・偽送信だけで待機状態へ入る。「裏を印刷」を押しても、同じ窓で次に始めた手動両面でも、実プリンターへの照会・送信や補正の永続化はしない。ライト・ダークと長い翻訳を確かめる。実機確認とは区別する。
     - 表示: `-SurimonoViewLayout single|spread`、`-SurimonoTransition scroll|instant|slide|fade|pageCurl`、`-SurimonoCoverAlone YES`、`-SurimonoRightToLeft YES`、`-SurimonoZoom <倍率>`
     - メニューと窓: `-SurimonoMenu full|always`（全体を表示 / 常に出す。旧 `compact` は `full`、`pinned` は `always` と同じ扱い）、`-SurimonoMenuArrangement top|split`（上だけ / 上と下に分ける）、`-SurimonoThenMenu always|onHover`（窓が紙に合ってからツールバーを常に表示に入れる / 切る。⌥⌘T と同じ。窓の伸び縮みを見る）、`-SurimonoPointer "x,y,ms;…"`（利用者のポインタの代わりに、始めたときの紙の左上からのずれ（pt、y は下向き）にポインタを置いて ms だけ待つ。乗せたときだけの帯の出し入れと窓の伸び縮みを確かめる）、`-SurimonoPointerLog <パス>`（その間 50 ms ごとの窓の枠と信号機の表示を書く。同じ高さが続けば、止まったポインタで帯がちらついていない）、`-SurimonoPopover view|style|printOptions|print|toc|stats`（表示のオプション / スタイルのパレット / 刷り台の印刷の設定のシート（`-SurimonoMode print` と合わせる）/ 表示モードの印刷の設定（窓の右の縁から出すポップオーバー。`-SurimonoFinishSheet <節>` でその節まで送る）/ 目次 / 文書の数字）、`-SurimonoOutline popover|drawer`（目次の出し方）、`-SurimonoOutlineDrawer YES`（目次の引き出しを開く）、`-SurimonoPaperSeries a|b`（A判 / B判）、`-SurimonoPaperHeight <pt>`（紙の高さ。狭い窓で帯の畳み方を見る）、`-SurimonoChanges jump|mark|ask`（更新の見せ方）、`-SurimonoWaitForChange YES`（開いたあとに呼び出し側がファイルを保存するのを待って撮る。一時ファイルで、起動を確かめてから保存する。Markdown の差分は約 1000 行を超えると印が付かない）、`-SurimonoAlwaysOnTop YES`、`-SurimonoSelectText YES`（文字を選択）、`-SurimonoDrawer YES`（画像の束のサムネイル）
     - 目次の吹き出し: `-SurimonoPopover outline`（`toc` と同じ。設定の出し方によらず吹き出しを開く）
     - 目次の引き出し: `-SurimonoOutlineDrawer YES`（この起動だけ引き出しを使い、設定には書かない）
     - しおり: `-SurimonoBookmarks 3,10,25`（1始まりのページにはさむ。通常の文書ごとの保存を行う）
     - 目次の絞り込み: `-SurimonoOutlineFilter <文字>`（開いた目次の欄に入れる。見出し8個以上の文書で使う）
     - 追加部品の撮影: `-SurimonoBandParts readingDirection,selectText,viewOptions,margins`（カンマ区切りの保存IDを指定。「Band Parts」という一時セットを選び、Splitの上・右の印刷直前に指定順で置く。新14部品を含む全27IDが使え、文書に適用されないものは実際の帯には出ない）。この引数だけでは撮影・印刷を始めない。配置・組み方はその起動中のメモリだけで、設定へ書かずセット保存も拒否する。`-SurimonoBandArrangement` と併用しない。
     - 印刷モード: `-SurimonoMode print`（刷り台で撮る）、`-SurimonoMode roundtrip`（刷り台に入って表示モードへ戻ったところを撮る）、`-SurimonoMode compare`（見比べ台で撮る。`-SurimonoComparePlace <n>` で n 番目の箇所からそろえ、`-SurimonoPopover comparePlace` で箇所の一覧を開く）、`-SurimonoTry <テーマの id>`（パレットで乗せたように紙で試したところを撮る）、`-SurimonoFold YES`（折ってみる）、`-SurimonoTray original|openDetails|currentSlide`（HTML の刷り台で「最初の状態で刷る」/「開いて刷る」/ スライドの「今の 1 枚」を選ぶ）、`-SurimonoSlides off`（「スライドとして表示」をオフにする）
     - 紙の仕上げ: `-SurimonoHeader none|number|name|nameAndDate`、`-SurimonoBreak h1|right`、`-SurimonoTOC head|hidden`、`-SurimonoMargins <上,左,下,右>`、`-SurimonoMirror YES`（内側・外側）、`-SurimonoSeries a|b`、`-SurimonoSet <組み込みの設定セットの番号>`、`-SurimonoFinishSheet YES`（詳細を開く。`furniture`・`breaks`・`contents`・`notes`・`printer` ならその節まで送る）、`-SurimonoNote <プリセットの id>`（ノートをオンにしてプリセットを選ぶ）、`-SurimonoNoteSide left|right|back|chapter`（ノートの入れ方）、`-SurimonoNoteAdjust YES`（「線を調整する」を開く）、`-SurimonoTraySize <幅>x<高さ>`（刷り台と見比べ台の窓の大きさ。見比べ台で 4 列を見るには幅 1280 以上）、`-SurimonoHidePrinters YES`（プリンター名を写さない）、`-SurimonoPages <範囲>`（刷り台の「ページ」の欄。`5-12` など。読めない文字ならエラーの表示を撮れる）、`-SurimonoCopies <部数>`、`-SurimonoPrinterLimits YES`（A4 と B5 の片面だけに刷れる架空のプリンターにして、刷れないレイアウトの札を見る）、`-SurimonoPrinterName <名前>`（その名前のプリンター 1 台だけを刷り台に出す。長い名前で下のバーの畳み方を見る。実在のプリンターと同じ名前でも、印刷・両面のテスト・手動両面はどれも外へ送らない）
     - 書き出し: `-SurimonoExport reading|png|html -SurimonoExportPath <絶対パス>`。最初の文書の組版後にパネルなしで実行する。reading / html はファイル、png は既存フォルダー（文書名の新規サブフォルダーを作成）。`-SurimonoExportDPI <n>` で PNG の解像度、`-SurimonoSnapshotQuit YES` で成功後に終了。開いた文書の上書きは拒否する。Release には含めない
     - スマート削除（HTML）: `-SurimonoSmartRemoval on|review`（オン / 確かめるパネルを開く）
     - コード: `-SurimonoCodePalette <配色の id>`、`-SurimonoCodeFrame style|none|tint|rule|left`、`-SurimonoCodeNumbers none|all|everyFive`、`-SurimonoCodeLong wrap|shrink|cut`、`-SurimonoCodeLabel none|corner|band`、`-SurimonoTryCode <配色の id>`（パレットの行に乗せたように紙で試す）
     - ページ送り: `-SurimonoTurn forward|back`（アニメーションを 10 倍遅くして 1 ページ送り、途中で撮る。送りの向きの確認用）、`-SurimonoTurnAt <0〜1>`（`-SurimonoTurn` と合わせ、送りをその割合の時点で止めて撮る。0.15・0.35・0.55・0.75・0.92 などを順に撮ると、めくりの動きをこま送りで見られる）
     - ページ: `-SurimonoPage <n>`（撮る前に n ページ目へ移る。`-SurimonoMode roundtrip` と合わせると、印刷モードから戻っても同じページかを見られる）
     - 画面: `-SurimonoScreen <n>`（撮る前に窓を `NSScreen.screens` の n 番目の画面へ移す。1x と Retina の両方で見るとき）
     - クリックの当たり: `-SurimonoHitMap <テキストの絶対パス>`（撮る直前に、窓の上 52pt を 4pt ごとにヒットテストして、信号機は `L`、タイトルバー（ツールバーの項目）は `T`、内容は `.` の地図と、ツールバーの項目のビューの枠を書く。上のバーの部品がタイトルバーに隠れていないかを見る）
     - 検索とページへ移動: `-SurimonoFind <語>`（⌘F で検索バーを開いてその語を打ったところを撮る）、`-SurimonoPopover goToPage`（「ページへ移動…」のシートを開く）
     - ウェルカム画面と同梱の案内: `-SurimonoSnapshotWelcome YES`（文書を渡さずに起動し、ウェルカムの窓を出して撮る。`open` で起動したアプリは前面に来ないことがあり、そのままではウェルカムの窓が出ないため直接出す）、`-SurimonoOpenGettingStarted YES`（ウェルカム画面やヘルプメニューと同じ経路で同梱の案内を開き、その窓を撮る。文書を渡さずに起動する。`-AppleLanguages "(en)"` で英語版）
     - クリップボード: `-SurimonoOpenClipboard <テキストファイルの絶対パス>`（起動時に、その文字列を専用のペーストボードから「クリップボードから開く」で開き、その窓を撮る。一般のクリップボードは触らない。形式が確かでない文字では聞く画面が出る）、`-SurimonoClipboardQuestion <テキストファイルの絶対パス>`（その文字をクリップボードから開いたものとして、判定の結果によらず形式を聞く画面を出して撮る。文書を一緒に `open` に渡すとその窓のシート、渡さなければ独立した窓。答えずに終わるので何も開かない）、`-SurimonoFormatMenu YES`（`-SurimonoOpenClipboard` と合わせ、帯の形式の札を押してメニューを開いたところを撮る）
     - サービスとストリーミング: `-SurimonoServiceText <テキストファイルの絶対パス>`（専用のペーストボードからサービスの受け手へ渡す。`-SurimonoService print` で「刷る」、省くと「開く」）、`-SurimonoStreaming <テキストファイルの絶対パス>`（専用のペーストボードでストリーミングプレビューを開く。`live` なら本物の `mkStreamingPreview` を見る）
     - 親ファイルの合本: `-SurimonoOpenIncludes YES`（描画のあと「合本で開く」を押し、合本の窓を撮る）
     - 印刷前の確認: `-SurimonoPopover issues`（刷り台へ入り、問題の一覧を開く。`Samples/preflight.md` で確かめる）、`-SurimonoMode print -SurimonoIssueFrame <n>`（n 番目の問題の「該当箇所を確認」を押し、表示モードの紙に枠が出ているところを撮る）
     - Release ビルドには含まれない。表示の引数で設定を変えると、その文書の設定として `~/Library/Application Support/Surimono Dev/DocumentSettings/` に保存される（次に開くと「戻しました」が出る）。確認用のファイルの記録は確認後に消す
     - 画像の束を撮るときは、`open` に画像を複数まとめて渡す（例: `open -n -W -a "$APP" a.png b.jpg c.heic --args …`）。束のウィンドウが撮られる。
     - 合本を撮るときは、`open` に種類の違うファイルを複数まとめて渡し、`-SurimonoDrawer YES` で引き出しを開く（例: `open -n -W -a "$APP" "$PWD/Samples/sample.md" "$PWD/Samples/sample.csv" --args -SurimonoDrawer YES …`）。
     - 前回のウィンドウの復元が混ざらないよう、確認用の起動には `-ApplePersistenceIgnoreState YES` も付けるとよい（`pkill` などで落とすと次の起動で文書が復元される）。
   - **PR に貼る注釈付きスクリーンショット**: 撮ったスナップショットに `swift .agents/skills/project-surimono-dev/scripts/annotate-screenshot.swift <入力.png> <出力.png> "x,y,w,h:ラベル" …` で赤い枠と番号付きのラベルを付ける（macOS 標準の CoreGraphics と AppKit だけで動く）。置き場と書き方は AGENTS.md の「Git / PR」。
   - **開き方の確認（ウィンドウの数と題名）**: `swift .agents/skills/project-surimono-dev/scripts/list-windows.swift` が開発版の画面上のウィンドウを前面から順に、レイヤー・位置・大きさ・題名つきで出す（題名は画面収録の許可がないと空になる。レイヤー 8 はアラートなどのモーダル。数えるのは名前が Surimono Dev の全プロセスの画面上のウィンドウで、公開版と最小化したものは含まない。一覧を取れなければ終了コード 1）。Finder や Dock からの開き方は `open -a "$APP" <ファイル…>` で再現し、AGENTS.md の「ウィンドウとファイルの開き方」の規則どおりの数と題名になるかを見る。
   - 操作まで確かめたい場合: Claude Code なら computer-use の `request_access`（開発版のバンドル ID `io.github.phyten.Surimono.debug`）→ `app_screenshot`（ユーザーが許可しなければ使わない）。それ以外は `screencapture -x -o -l "$(swift .agents/skills/project-surimono-dev/scripts/window-id.swift)" /tmp/surimono.png`（実行するターミナルに画面収録の許可が必要）。
   - ライト / ダークの両方と、空・読み込み中・エラー・長い文書の状態を見る。表示モードはメニューの出し入れ（上端と下端の帯の場所で全体を表示 / 離れて 1 秒で非表示 / 常に出す）と、単ページ・見開きを見る。選択肢は単ページ → 見開きで、⌥⌘1・⌥⌘2、Tab・矢印キー・VoiceOver の順も見た目にそろうことを確かめる。冊子は書き出した PDF か印刷パネルのプレビューで面付け（1 枚目の表が [最終ページ | 1]）も確かめる。
4. 終わったら起動したアプリを終了する: `osascript -e 'quit app id "io.github.phyten.Surimono.debug"'`（名前で指定すると、入れてある公開版を終了してしまう）。

## つまずきやすい点

- `make` が失敗したら、まず `xcodebuild -version` と `swift --version` で Xcode を確かめる（CI は Xcode 26.6、ローカルは 27 系を想定）。
- パッケージ解決のエラーは `rm -rf build/DerivedData Packages/SurimonoKit/.build` の後に再実行する。
- WebKit を使うテストが時々落ちるときは、単発の成否で判断せず、複数回実行して失敗率を見る。
- ファイルを追加しても `Surimono.xcodeproj` の編集は不要（synchronized folder）。ビルド設定は `Configs/*.xcconfig` で変える。
