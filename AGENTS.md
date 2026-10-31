# AGENTS.md — Surimono

このリポジトリで作業する AI エージェント（Codex、Claude Code など）共通の指示。人間向けの案内は [CONTRIBUTING.md](CONTRIBUTING.md)。

## プロダクト

- **Surimono（摺物）**: Markdown / PDF / 画像 / Org / テキスト / HTML / LaTeX を「雑に開いて、雑に見て、さっと刷る」macOS アプリ。主役は印刷。
- 主な機能: 出てくる用紙をそのまま並べる印刷モード（刷り台）、印刷テーマ（CSS。12 のカテゴリーに 95 種。文書の 1 ページ目の見本を並べたパレットで、最近使った・お気に入り・定番・カテゴリーから選べ、乗せると紙で試せる。4 つまで並べる見比べ台もある）の切替とユーザー CSS・文字の大きさ、HTML のノイズ除去プリセット（ユーザー追加可）とスマート削除（ベータ）、印刷レイアウト（A4 片面・両面、中綴じ冊子 A3→A4 / A4→A5、2アップ）、刷り台で選んだプリンターへのダイアログなしの印刷（システムの印刷画面も選べる）、PDF 書き出し、余白のない表示モード（段階表示のメニュー、見開き / 単ページ、拡大縮小、最前面に固定）、内容のハッシュごとの設定の保存、複数の画像や ZIP の中の画像をまとめた「画像の束」（並び替え・印刷・PDF 書き出し）。外観はシステムの設定に従う（アプリに切替は置かない）。
- 守ること:
  - **開いたファイルを絶対に変更しない**（ビューア。保存・上書き・隣へのファイル生成もしない）
  - **オフラインで完結する**（ネットワークは、ユーザーの文書自身が参照するリソースの読み込みと、アップデートの確認（「配布とアップデート」）に限る。テレメトリなし）
  - **2 手で印刷できる**（開く → 印刷）。迷ったら操作を減らす方を選ぶ

## リポジトリ構成

```text
App/                    アプリ本体（SwiftUI）。Xcode の synchronized folder なので、ファイル追加で pbxproj を編集しない
AppTests/               アプリのテスト（ホストアプリ付き）
Configs/                xcconfig・Info.plist・entitlements。ビルド設定はここで変える
Packages/SurimonoKit/   ロジック本体（SwiftPM）
  Sources/SurimonoCore/       純粋ロジック（形式判定、HTML への変換、テーマ・プリセット、用紙・レイアウト、面付け計算）。AppKit / WebKit / PDFKit に依存しない
  Sources/SurimonoRendering/  AppKit / WebKit / PDFKit / CoreGraphics を使う描画（ページ分割、画像の PDF 化、面付け PDF の合成、印刷設定）
  Tests/                      Swift Testing のテスト
Samples/                手動確認用のサンプル文書
Design/                 アプリアイコンの原画（AppIcon.svg と、開発版の AppIcon-Dev.svg・AppIcon-Dev-small.svg。App/Assets.xcassets の PNG はここから書き出す）
Surimono.xcodeproj      手書きの最小プロジェクト（objectVersion 77）
.github/workflows/      CI（ci.yml）、リリース（release.yml）、ダウンロード数（download-stats.yml）
.agents/skills/         プロジェクト固有スキル（正本。Codex が読む）
.claude/                Claude Code 用（settings.json、rules/、skills は .agents/skills へのシンボリックリンク）
.docs/                  ローカル専用の開発資料（gitignore 済み。コミットしない）
```

## コマンド

```bash
make build                      # Debug ビルド（build/DerivedData。開発版の Surimono Dev）
make run FILE=Samples/sample.md # ビルドしてファイルを開く（FILE 省略可）
make test                       # test-kit と test-app の両方
make test-kit                   # SurimonoKit のテスト（swift test）
make test-app                   # アプリのテスト（xcodebuild test）
make lint                       # swift-format lint --strict
make format                     # swift-format で整形
make package                    # Release ビルド → build/release/Surimono-<version>.dmg と .zip（それぞれ SHA-256 付き）
make clean
```

- 変更したら最低限 `make lint` と、変更範囲のテスト（Kit なら `make test-kit`、アプリなら `make build` と `make test-app`）を通す。
- Debug ビルド（`make build`・`make run`・`make test-app` のホスト）は公開版と別のアプリ「Surimono Dev」になる。バンドル ID `io.github.phyten.Surimono.debug`、アイコン `AppIcon-Dev`（暗い地に黄色の DEV の帯）、保存先 `~/Library/Application Support/Surimono Dev/` で、設定（UserDefaults）も公開版と共有せず、入れてある公開版と同時に起動できる。
  - 分け方: `Configs/Surimono.xcconfig` の `[config=Debug]` と `UserLibrary.defaultRoot` の `#if DEBUG`。`DevelopmentBuildTests` で固定している。
  - `PRODUCT_NAME` は Makefile と `TEST_HOST` が `Surimono.app` を参照するので変えない。
  - `AppIcon-Dev` は、Dock や ⌘Tab でも公開版と取り違えないよう、全体の明るさと帯の色で分ける。原画は、`Design/AppIcon.svg` を暗い地に置いて少し暗くし、黄色の注意の帯（縞と DEV の文字）を重ねた `Design/AppIcon-Dev.svg` と、16・32px 用に縞と文字を省いて帯を太くした `Design/AppIcon-Dev-small.svg`。どちらも `AppIcon.svg` に行を足しただけで、元の行は変えていない。`AppIcon` と同じく `rsvg-convert -w <px> -h <px> <SVG> -o <名前>.png` で、`icon_16x16`・`icon_16x16@2x`・`icon_32x32` は `AppIcon-Dev-small.svg` から、残りの 7 枚は `AppIcon-Dev.svg` から書き出す。`AppIcon.svg` を変えたら、2 つの SVG にも同じ変更を入れて書き出し直す。
- CI（`.github/workflows/ci.yml` の `build-and-test`）は Xcode 26.6 / macOS 26、ローカルは Xcode 27 系を想定。**両方でビルドできるコードにする**。`if #available` は実行時の OS の分岐で、古い SDK でのコンパイルは助けない。CI の SDK（Xcode 26.6）に無い API は使わず、どうしても使う場合は `#if compiler(>=…)` などの条件付きコンパイルと代替の実装を用意する。

## アーキテクチャ（印刷パイプライン）

```text
ファイル → DocumentFormat 判定
  ├ Markdown / Org / テキスト / CSV / LaTeX → HTML 断片（SurimonoCore）→ 印刷テーマ CSS を付けて HTML 文書化（テーマは `common.css` の後に重ね、その後に文字の大きさを重ねる。WebKit の印刷では CSS の段組みが効かないので、段組みのテーマは作れない）
  ├ HTML → そのまま。ノイズ除去プリセット（CSS / JS）を注入
  ├ PDF  → PDFDocument
  └ 画像 → PDF ページ（ImagePageRenderer）
→ 論理ページの PDF（WebPaginator: WKWebView を NSPrintOperation で論理ページ寸法に組版）
→ 面付け（PDFComposer: レイアウトに従って用紙へ配置。冊子・2アップ・ページ番号・裏面回転）
→ プレビュー（PDFView）/ 印刷（PrintJobFactory: 用紙・向き・両面を設定した NSPrintInfo）/ PDF 書き出し
```

- これらを束ねるのが `DocumentRenderer`（SurimonoRendering）。文書ごとに 1 つ持ち、論理ページの PDF を使い回す（両面設定やページ番号の変更だけなら組版し直さない）。ファイルが変わったら `clearCache()` を呼ぶ。
- Markdown と Org のコードは SurimonoCore の `SyntaxHighlighter` で色付けする（JavaScript は使わない）。Markdown の `:::` と `> [!note]` は囲み（`callout-*`）にする。
- `:::` は markdown-it-container と同じく、段落・参照定義・引用・リストの続きを打ち切る（コード・HTML・明示的な引用行・字下げしたリスト本文・AST のブロックに属さない行は除く）。
- Markdown の拡張記法（`MarkdownExtensions`、SurimonoCore）: 脚注 `[^id]`、`==ハイライト==`、`^上付き^`、`~下付き~`（pandoc と同じく `~~` は取り消し線）、ルビ `{漢字|かんじ}`・`{漢字|かん|じ}`、絵文字 `:name:`、定義リスト（語の次の行の `: 説明`）、見出しの ID（GitHub と同じ slug、`{#id}` で指定）と目次 `[TOC]`。
  - インラインの記法は、cmark の前に原文を inline HTML へ書き換える。中の Markdown もそのまま読まれ、表の `|` とも混ざらない。コードブロック・HTML ブロック・コードスパン・タグ・リンク先・URL は書き換えない。
  - 脚注は最初に参照した順に番号を振り、本文は末尾の `section.footnotes` にまとめる。紙からは戻れないので、戻りのリンクは付けない。
  - 絵文字の対応表 `Resources/emoji.json` は GitHub の gemoji（MIT）の別名だけを取り出したもの。ライセンス文を `App/Acknowledgements/` に同梱している。
  - 数式 `$…$`・`$$…$$`（複数行も）・`\(…\)`・`\[…\]`・```` ```math ```` は、SwaTex（純 Swift の KaTeX 互換の組版）で SVG にする（`MathRenderer`）。式は cmark の前に取り出し、インラインは私用領域の文字の目印、行をまたぐものは HTML ブロックにするので、強調やエスケープが LaTeX に触れない。インラインの `$` は式に接していて後ろに数字が来ないときだけ（`$5 と $10` は文字のまま）。字形は KaTeX の書体の `<text>` で、使った書体だけを本文の最後の `<style>` に data URL の `@font-face` で埋め込む（文書の隣のファイルを読まずに刷れる。テーマの「Web フォントを使わない」とは別で、アプリが同梱する数式用の書体）。大きさは em（文字の 1.1 倍）、色は `currentColor` でテーマに従う。読めない式は原文を `.math-error` で残す。
- LaTeX（`.tex`・`.latex`・`.ltx`、UTType `org.tug.tex`）は `LaTeXConverter`（SurimonoCore）が HTML 断片にする。TeX エンジンではなく、よく使う部分集合を読んで印刷テーマで刷る（Swift で書かれた TeX エンジンはなく、Tectonic などは TeX Live の同梱とネットからの取得が要るため）。
  - 読むもの: 前置きの `\documentclass`・`\title`／`\author`／`\date`・`\newcommand`／`\def`・`\DeclareMathOperator`・`\definecolor`・`\graphicspath`、`\maketitle`、abstract、`\tableofcontents`、番号つきの節（章のある文書クラス、`\appendix`、和文の文書クラスは「第1章」）、`\label`／`\ref`／`\eqref`、書体とサイズ、itemize／enumerate（enumitem の `label=`・`start=`）／description、quote・center など、verbatim・lstlisting・minted（色付けは `SyntaxHighlighter`）、`\verb`、数式（`$`・`\(`・`\[`・equation・align などは SwaTex。星なしの環境に式番号）、`\footnote`、hyperref の `\href`／`\url`、xcolor、figure／table の `\caption`（図と表は別の番号）、graphicx の `\includegraphics`（拡張子がなければ文書の隣と `\graphicspath` を探す）、tabular（列の揃え・縦線・`\hline`・booktabs・`\multicolumn`・`\multirow`）、amsthm の `\newtheorem`（節ごと・共有・番号なし、`\theoremstyle`。和文の文書は plain でも斜体にしない）と proof、thebibliography と `\cite`（natbib の `\citep` なども番号で）、siunitx の `\num`・`\qty`（`\SI`）・`\unit`（`\si`）・`\ang`（数式の中でも使える）。
  - 前置きの `\newcommand` は文章の中では展開し、数式には定義として渡す（SwaTex が読めない定義は外す）。知らないコマンドは名前を捨てて引数の文字を残し、設定だけのコマンド（`\setlength` など）は引数ごと消す。geometry は無視して Surimono の用紙と余白を使う。TikZ などの図と `\input`・`\bibliography`（.bib）は、描けない・読まないことを枠で示す。
  - 改行をはさんだ和文の文字の間には空白を入れない（和文の TeX と同じ）。参照・文献の番号・目次は文書の終わりまで読んでから埋める。`\bibitem` のない `\cite` はキーを太字で出す。
- JavaScript: Markdown / Org / テキスト / CSV / LaTeX から作る HTML では、文書の JavaScript は常に無効。HTML 文書は設定（既定は許可）とプリセットの両方が許すときだけ有効。組み込みテーマの飾りのスクリプトは例外で、組版の準備としてアプリの隔離された世界（`world(name: "surimono")`）で走り、文書のスクリプトとは混ざらない。
- 印刷テーマの目録は `Resources/themes.json`（SurimonoCore）: カテゴリー（順と名前）、定番の順、各テーマの id・英語名・日本語名・カテゴリー・飾りのスクリプトを持つ。テーマの CSS は `Resources/<id>.css` で、`common.css` の後に重ねる（`PrintThemeLibrary`）。メニューの並び（最近使った 5 つ・お気に入り・定番・カテゴリー・自分のスタイル）は純粋な型 `PrintThemeMenu` が決め、テストで固定している。
  - テーマを足すときの決まり: `@page`・CSS の段組み・`position: fixed`・アニメーション・外部の URL・Web フォントは使わない。書体は macOS に入っているものだけで、最後に日本語の書体と総称の書体を置く。例外として、アプリが同梱する KaTeX の書体を `ThemeFonts`（SurimonoCore）の名前 `"Surimono Computer Modern"`・`"Surimono Computer Modern Typewriter"`（引用符つき）で使える。使ったスタイル（ユーザー CSS も）にだけ、欧文の範囲に絞った data URL の `@font-face` がスタイルの要素に入る（パレットが要素を差し替えても書体が付いてくる）。数式の書体とは別の名前で欧文の範囲に絞るので、和文や … ・矢印はこの書体を使わず、テーマの書体の並びで次の書体に任せる（「LaTeX 風」テーマが使う）。パレットは要素を差し替えたあと、書体の読み込みを待ってから見本を描く。見出しに CSS のカウンターで番号を振るときは、`body:not(.format-latex)` を付けて LaTeX の文書を外す（LaTeX は自分で番号を持つ）。紙の地は白かごく淡い色にする（インクを使い切らないため）。本文は 4.5:1 以上のコントラストにする。
  - 紙の色や模様は `html` に書き、`body` の背景は `transparent` にするか `html, body` で同じ色にする（`body` の背景は本文の範囲にしか出ない。テストで固定している）。模様は SVG の画像か放射状のグラデーションで描く（固い境目の線形グラデーションを `background-size` で並べると、WebKit の印刷で細い横縞になった）。1 本だけの縦線は `repeat-y` にする（横にも並ぶと右の余白に 2 本目が出る）。
  - 飾りのスクリプト（`decorations.js`）は、テーマの `--deco-emoji` から絵文字を選び、見出し・箇条書き・区切り線に `data-deco` を付ける。乱数の種は本文の文字から作るので、同じ文書なら画面と印刷で同じ絵柄になる。テーマの CSS が `attr(data-deco)` で見せる。
- 紙の地: テーマが `html` に白以外の背景（色・画像）を付けていれば紙とみなす。WebKit は余白に背景を描かないので、本文のページは紙を外すスタイル（`PaperBackground.removalStyle`。最初から文書に入れる）と下地なし（`drawsBackground: false`）で組み、紙だけのページ（根要素の中身を本文の範囲に置いた空の文書。`PaperBackground.document`）を余白なしで別に組んで、`PaperComposer` で各ページの下に敷く（リンクも付け替える）。模様は本文の左上を起点にそろい、余白にも続く。横にはみ出して縮む文書だけは紙を本文に残す（余白は白のまま）。パレットの見本も同じ組み方で、余白を含む論理ページ全体を描く。

- 論理ページ寸法: 通常は用紙そのもの。冊子と 2アップは用紙の半分（A3 → A4、A4 → A5、B4 → B5）。Web 系の文書は論理ページ寸法で組版し直し、PDF と画像は縮小して収める。
- 中綴じ面付け（ページは 1 始まり、n は元のページ数）:

  ```text
  N = ceil(n / 4) * 4、用紙枚数 = N / 4
  用紙 s（0 が一番外側）: 表 = [左 N-2s | 右 2s+1]、裏 = [左 2s+2 | 右 N-2s-1]
  n を超えるページは白紙。両面は短辺綴じ
  ```

  例: n = 8 → 用紙1 表[8|1] 裏[2|7]、用紙2 表[6|3] 裏[4|5]。この式はテストで固定している。変更するときはテストと `.agents/skills/project-surimono-print-layout` を先に更新する。
- 外での保存: `FileWatcher` がパスのメタデータを 250 ms ごとに裏で見て（エディタは保存でファイルを差し替えることが多いので、開いたファイルではなくパスを見る）、変わったら `DocumentViewModel` が裏で読み直す。内容が同じなら組み直さない。手で押した再読み込みはいつも読み直す。イベントの見張り（vnode）と比べ、速さと負荷の差は誤差で、ネットワークやクラウドの場所では届かないことがあるのでポーリングのままにしている。
- Markdown の変更の印: 読み直したとき、前に表示していた原文と行ごとに比べ（`MarkdownChanges`。前処理をまたいで原文の行とブロックを対応づける）、変わったブロックの位置を、各ブロックに見えないリンク（`surimono-mark:`）を置いた別の組版から WebKit のリンク注釈として受け取る（`ChangeMark`）。表示・印刷に使う組版には何も足さず、線は表示用の写し（`ViewPageDocument`）にだけ、本文の左端のすぐ外に描く。HTML・Org・LaTeX には印を付けない。
- 依存の向き: App → SurimonoRendering → SurimonoCore。Core から AppKit / WebKit を import しない。
- アプリの既定値（既定のレイアウト・余白など）と、スタイルの最近使ったもの・お気に入り（アプリ全体）は `AppPreferences` が `UserDefaults` に保存する。スタイルを選んだと記録するのは利用者がメニューで選んだとき（`DocumentViewModel.selectTheme`）だけで、復元・既定に戻す・代わりのテーマへの切り替えでは記録しない。ユーザー CSS とユーザープリセットは `~/Library/Application Support/Surimono/` 配下の `Styles/`（*.css）と `Presets/`（*.json）に置く（`UserLibrary`。Debug ビルドは `Surimono Dev/` 配下）。
- 文書ごとの設定（表示の型・向き・送り方・表紙・拡大率・窓の大きさ・印刷レイアウト・スタイル / プリセット・文字の大きさ・印刷のオプション・画像の並び順）は `DocumentSettings` にまとめ、**ファイル名ではなく内容の SHA-256（`ContentHash`）をキーに** `~/Library/Application Support/Surimono/DocumentSettings/`（`KeyedRecordStore`。Debug ビルドは `Surimono Dev/` 配下）へ保存する。
  - キー: 1 ファイルはその内容、ZIP は ZIP ファイル自体、画像の束は各画像のハッシュを並べ替えて作る集合のハッシュ（`ContentHash.imageSet`。書式は永続化の形式なので変えない）。並び順は各画像のハッシュの列で保存する。
  - 保存は利用者が何かを変えたときだけ（`DocumentViewModel` が読み込み・復元・既定に戻した時点の値と比べる）。開いている間にファイルが変わったら、表示中の設定を新しいハッシュへ引き継ぐ。

## ウィンドウとファイルの開き方

- **1 つの刷り物（1 ファイル、または画像の束）= 1 つのウィンドウ**。表示中のウィンドウにドロップしても置き換えず、新しいウィンドウで開く。すでに開いているファイルは前面に出す。
- ユーザーがファイルを選ぶ・渡す・ドロップする経路は、標準メニューの「最近使った項目」を除いて `OpenRouter`（App）を通す。分類は `OpenRequest`（SurimonoCore）:
  - 1 つ → 文書として開く（DocumentGroup / `NSDocumentController`）
  - 2 つ以上ですべて画像（種類の混在は可）→ 画像の束（ファイル名の自然順）
  - 2 つ以上で画像以外を含む → 何も開かずに警告（ウィンドウへのドロップならそのウィンドウのシート）
- 経路ごとの入口:
  - Finder / Dock / 「このアプリケーションで開く」: `AppDelegate` が open-documents の Apple Event を受ける（`applicationWillFinishLaunching` で登録）
  - ファイル > 開く…: 標準の項目が送る `openDocument:` を `AppDelegate` が受ける（SwiftUI の AppDelegate が応答チェーンで転送する）。独自の「開く…」をメニューに足さない（標準の項目と重複し、標準の側は文書コントローラが 1 つずつ開いてしまう）
  - ドロップ: 文書・画像の束・ウェルカム画面の `.dropDestination`
  - 最近使った項目: 標準メニューの項目は文書コントローラが 1 ファイルを開く（規則と同じ結果になるので、ルーターを通さないままでよい）。ウェルカム画面の最近使ったファイルは `OpenRouter` を通す
- 画像の束は NSDocument ではなく、`ImageBundleWindows` が AppKit の NSWindow に SwiftUI の `DocumentContent` を載せて開く。メニュー操作は `DocumentWindows.activeModel`（キーウィンドウのモデル）に届ける。
- ZIP は 1 つのファイルとして DocumentGroup で開き、中の画像を `ZipArchive`・`ZipImageSelection`（SurimonoCore）で集めて `ImageBundleModel` の束にする。ディスクへ展開せず、メモリ上で必要なときに 1 枚ずつ展開する。
- 新しい「開く」経路を足すときは `OpenRouter` を通し、`OpenRouterTests` にケースを足す。

## HTML のスマート削除（ベータ）

- 選んだプリセットのあとに、本文でない部分（広告・おすすめ記事・SNS ボタン・Cookie バナー・追従ヘッダー・ニュースレター欄・ポップアップ）を見つけて消す。判定は組版の準備スクリプトとして WKWebView の中だけで行い、外には何も送らない（`SmartRemovalScript`、SurimonoCore）。
- 本文の領域を 1 つに絞り、本文とその祖先、本文らしい見出しと段落の塊は消さない。候補の識別子は同じ HTML なら毎回同じで、「残す」の選択に左右されない。
- アプリは `RenderSettings.smartRemoval`（HTML のときだけ）で頼み、`RenderResult.smartRemovalCandidates` で候補を受け取る。確かめている間は消さずに点線の枠で示す。オンかどうかと「残す」の一覧は、文書ごとの設定として内容のハッシュで覚える。
- 確かめるパネルは表示モードにだけある。メニューとトーストからは `reviewSmartRemoval()` で開き、刷り台からなら表示モードへ戻る。枠つきのページは出力に使わない（`canOutput` が偽）。印刷モードに入ると確認を終え、確認中の印刷と PDF の書き出しは、確認を終えて枠のないページができてから行う。

## 印刷モード（刷り台）

- 表示モードの「印刷」・⌘P で入り、Esc・「表示に戻る」で戻る。印刷モードの朱の「印刷」と ⌘P は、刷り台で選んだプリンターへダイアログなしで送る（プリンターはアプリ全体で `AppPreferences.printerName` に覚え、外されていればシステムの既定。1 台もないときと、刷り台に出ていたプリンターが印刷の直前に外されていたときは、別のプリンターへ黙って送らずにシステムの印刷画面を開く。判断は `PrinterList.request`）。システムの印刷画面は ⌥⌘P と、プリンターのメニューの「システムの印刷画面で印刷…」から。⌘1〜⌘6 はレイアウトを選んで印刷モードへ。モードはウィンドウごと（`DocumentViewModel.mode`）。
- 入るときに `PrintModeWindow` が窓の枠を覚えて刷り台の大きさ（約 1000×760）へ広げ、戻るときに元の枠へ戻す。表示モードの縦横比の固定は入るときに外し、戻ってから付け直す。
- 刷り台は面付けした PDF（`sheetDocument`）の各面をベクターのまま描く。用紙ごとのまとめ方・見出し・ラベルは純粋な型 `PrintTray` にあり、テストで固定している。冊子は「折ってみる」で、読む順にめくって確かめられる。
- 配色は案 C の和紙・墨・朱・藍（`PrintPalette`。ダークでは夜の色）。朱は「印刷」ボタンだけに使う。

## 表示モードのウィンドウ

- ウィンドウには紙だけを余白なしで出す（`ViewerWindow`: タイトルバーを隠し、信号機はメニューと一緒に出す）。窓の縦横比は表示中のページか見開きに固定する。
- メニューは段階表示（`OverlayMenuState`）: 乗せると約 80 ms でファイル名と「印刷」、上部に留まると全部、離れて約 800 ms・静止 2.5 秒・ページ送りで隠す。Tab / M で出す、Esc で隠す、V で表示のオプション、T で文字を選択、⌥⌘T でメニューを固定（窓を上へ帯の高さだけ伸ばし、紙は動かさない）。
- 帯には、スタイル・表示の型・向き・スクロール・送り方・表紙（見開きのとき）・文字を選択（画像以外）・拡大率（拡大中）・サムネイル（画像の束）・最前面に固定・メニューを固定・「…」・印刷を直接並べる。幅が足りないときは `BandLayout`（SurimonoCore）の決まった順に畳む: まずスタイルと送り方の名前を省き、次にメニューを固定・最前面に固定・形式のバッジ・表紙・スクロール・向き・ページ表示・スタイル・送り方・表示の型の順に帯から外す。ファイル名は 80pt まで縮めて残し、印刷は最後にアイコンだけになる。外した物は「…」のメニューに並び、最後の「表示のオプション…」（V）でポップオーバーを開く。余白は表示のオプションと「…」のメニューからも変えられる（刷り台と共有する `MarginControl`。PDF と「A4 3枚＋メモ」では紙に効かないので出さない）。帯の背景は、ポインタが窓の中にあるだけのときは薄く、帯の上・帯から開いたメニューやポップオーバーがある間・固定中・「透明度を下げる」がオンのときは元の濃さで描く（`OverlayMenuState.isPointerOverBand`）。部品の幅は見えない所で形ごとに測り（`BandMeasurements`）、測った値は帯が消えても `OverlayMenuState` に残す。スクロールは、効かない送り方（切り替え・フェード・めくり）のときは隠さずに薄くする。
- 紙は `PaperView`（PDFView）。`ViewOptions`（SurimonoCore）を PDFView の表示モード・`displaysRTL`・`displayDirection` に当てはめ、ページ送りのアニメーション（スライド・フェード・めくり・重ねる・引き抜く・ワイプ・ズーム）、拡大縮小（ピンチ・⌘＋スクロール・⌘＋/−/0・ダブルクリック）、キー操作、紙のドラッグでの窓の移動を受け持つ。「文字を選択」（`DocumentViewModel.isSelectingText`。窓ごとで保存しない）のときは、ドラッグ・クリック・ダブルクリックを PDFKit の文字の選択に渡し、端のクリックでページを送らない。⌥ を押している間は二つのドラッグが入れ替わる。カーソルは、文字を選択のときだけ PDFKit の I ビームに任せ、それ以外は矢印（拡大中は手のひら）にする。拡大中に素早く閉じるピンチで 100% に戻る。100% 未満はゴムで、離すと戻る。
- ホイールとトラックパッドは、PDFKit の内側のスクロールビューが先に受け取って効果なしにページを送ってしまうため、`PaperPDFView` がローカルのイベントモニタで紙の上のスクロールを受けて `turnPage` を通す。スクロールの系列ごとに、始まった場所で紙かパネルかを決めて慣性が終わるまで変えない（`WheelSequence`）。送るかどうかは `WheelPageTurner`（SurimonoCore）が感度（`AppPreferences.wheelSensitivity`、低い・ふつう・高い）で決め、ふつうでもホイール 1 刻みでは送らない。連続スクロール・拡大中・⌘＋ホイールは PDFKit と拡大に任せる。
- メニューバー: 表示（この窓の見え方）・文書（印刷レイアウト ⌘1〜⌘6・スタイル・画像・リセット・再読み込み）・設定（アプリ全体: 感度・既定のページ送り・新しい文書の表示・ページをつなぐ・表示と印刷のページ番号・既定の印刷レイアウト／余白／スタイル・すべての設定…）。⌘, はアプリのメニューの標準の「設定…」だけが持つ（`SettingsMenuTests` で固定）。新しい文書の表示と既定のページ送りは「自動」が既定で、明示した値だけが、保存した設定と形式ごとの決まりの下で効く（`ViewDefaultPreferences`）。設定画面はサイドバーの形（`SettingsSection`）。

## スタイルのパレットと見比べ台

- テーマを使う形式（Markdown・Org・テキスト・CSV・LaTeX）では、帯のスタイルのボタンと「…」の「見本から選ぶ…」がパレット（`ThemePalette`）を開く。HTML のプリセットと刷り台のスタイルは今までどおりメニュー（`ThemeMenuContent`）。
- パレットは窓の右の縁から外へ出す（`ThemePaletteAnchor`、`arrowEdge: .trailing`）。帯のボタンの下に出すと紙を覆い、乗せて試しても見えないため。窓が画面の右端にあると、macOS が左へ出す。
- 見本: `ThemeSampler`（SurimonoRendering）が、文書を隠した窓の WKWebView に一度だけ読み込み、テーマごとにスタイルと飾りだけを差し替えて、1 ページ目の範囲を `createPDF` でベクターにし、余白を含む論理ページの 1 ページに置く（1 テーマ 0.1 秒弱。紙のあるテーマは、紙だけを別の WKWebView で描いて下に敷く）。画面用の描画なので、刷った 1 ページ目とわずかに違うことがある。アプリでは `ThemeSamples` が、文書・用紙・余白・文字の大きさが同じあいだ見本を覚え、見えたセルの分だけ描く。
- 乗せて試す: `ThemeTrial` が別の `DocumentRenderer` で文書全体を組み直し（約 200 ms 待ち、新しい要求で前を取り消し、最近 6 件を覚える。本番の組版中は待つ）、紙は `paperDocument` で試しのページを出す。試しているテーマを選ぶと、本番のページができるまで試しのページを出し続ける（`chosenTrial`）。直前の組版が `hoverTrialLimit`（1.5 秒）を超えた文書では試さず、クリックで切り替える。
- 見比べ台: `ViewerMode.compare`。刷り台と同じく `PrintModeWindow` が窓を約 1100×780 に広げて戻す（見比べ台から刷り台へ移っても、最初に覚えた表示モードの枠を残す）。候補は `ThemeComparison`（SurimonoCore。いまのスタイルは外れない。満杯で足すと、いま以外で一番前からある候補と入れ替わる）で、窓のあいだ覚える。配色は刷り台と同じで、藍の上の文字は `PrintPalette.raised`（夜の藍は明るく、白い文字が読めない）。
- 地雷: 帯の部品は `BandMeasurements` が見えない所にもう一組描いて幅を測るので、部品の中に `.popover` を付けると二重に出る。帯から出すポップオーバーは帯の側（`OverlayBand.tools`）か、帯の外の動かない場所に付ける。

## 配布とアップデート

- リリースは `v*` のタグで動く release.yml が作る（手順は `project-surimono-release`）。GitHub Releases に、新しく入れる人向けの DMG（アプリと `/Applications` へのリンク）、アプリ内アップデート用の ZIP、それぞれの SHA-256、`appcast.xml` を載せる。
- アプリ内アップデートは Sparkle 2（`AppUpdater`）。公開版は Info.plist の `SUFeedURL`（`releases/latest/download/appcast.xml`）を読み、`SUPublicEDKey` の公開鍵で ZIP の EdDSA 署名を確かめてから入れ替えて再起動する。
  - 自動の確認は、Sparkle が 2 回目の起動で利用者に聞く（`SUEnableAutomaticChecks` を Info.plist に書かない）。許されていれば、Sparkle の 1 日ごとの確認に加えて起動のたびに裏で確認する（`AppUpdater.checkOnLaunch`。Sparkle だけでは前回から 1 日たつまで起動しても確かめない）。断られたら、メニューの「アップデートを確認…」のときだけ通信する。設定の「一般」でも切り替えられる。システム情報の送信（`SUEnableSystemProfiling`）は使わない。
  - 開発版は `SURIMONO_UPDATE_FEED_URL` が空なので Sparkle を起動せず、メニューにも出さない（`AppUpdaterTests`）。
  - appcast は、各リリースが自分の ZIP だけを載せる。配られるのは GitHub の「Latest」のリリース（プレリリースは配らない）。
  - 秘密鍵は、メンテナのログインキーチェーン（Sparkle の `generate_keys`、アカウント `io.github.phyten.Surimono`）と、リポジトリの Secret `SPARKLE_PRIVATE_KEY` にある。なくすと、入れてある版はその後の更新を確かめられず、入れ直しになる。鍵を替えるときは Sparkle の鍵の切り替えの手順に従う。
  - Sparkle の道具（`generate_appcast`・`sign_update`・`generate_keys`）は、パッケージを解決すると `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/` にできる。
- ダウンロード数: download-stats.yml が毎日と Release ワークフローの成功後（GITHUB_TOKEN で作ったリリースは `release` イベントで他のワークフローを起動しないため `workflow_run` で受ける）に、GitHub Releases の DMG と ZIP のダウンロード数をそれぞれ合計し、shields.io の endpoint 用の JSON として `stats` ブランチに 1 コミットで上書きする。README のバッジがそれを読む。数は取得の回数で、入れた数や更新した数ではない（ZIP はアプリ内アップデートにも、手で入れるのにも使う）。appcast と SHA-256 は数えない。数は GitHub が持つものだけで、アプリからは何も送らない（テレメトリなし）。
- 署名はアドホックのまま（Developer ID・公証はまだ）。そのため Library Validation を外している（地雷を参照）。

## コーディング規約

- Swift 6 言語モード。アプリターゲットは既定で MainActor 分離（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）。Kit では UI / WebKit を触る型に明示的に `@MainActor` を付ける。
- デプロイメントターゲットは macOS 15.0。
- 依存パッケージは最小限。追加するときは理由とライセンス（MIT と両立するか）を PR に書く。現在の外部依存: swift-markdown（Apache-2.0）、Sparkle（MIT。アプリだけ。版は `Surimono.xcodeproj` で固定し、ライセンス文を `App/Acknowledgements/` に同梱している。版を上げたら差し替える）、SwaTex（MIT。SurimonoCore の数式。0.x なので版を固定している）。SwaTex が同梱する KaTeX の書体（SIL OFL 1.1）は SurimonoCore の `Resources` に写して使い、ライセンス文を `App/Acknowledgements/` に同梱している。SwaTex を上げたら書体も写し直す。
- UI 文言は英語をキーにして String Catalog（`App/Localizable.xcstrings`）で日本語訳を付ける。
- 整形は swift-format（`.swift-format`。インデント 4、行長 120）。
- コメントは「なぜそうするか」を書く。自明な処理の説明コメントは付けない。**コードコメントとドキュメントコメントは英語**で書く（テスト名は日本語）。
- ビルド設定を変えるときは `Configs/*.xcconfig` を編集する。Xcode の GUI でターゲット設定を変えない。

## 細則（.claude/rules/）

パス別の細則は `.claude/rules/` にある。Claude Code は対象ファイルを扱うときに自動で読み込む。**Claude Code 以外のエージェントも、該当するファイルを編集する前に読むこと。**

- `.claude/rules/swift.md` — Swift（並行性、エラー、ファイルの扱い、SwiftUI / AppKit）
- `.claude/rules/tests.md` — テスト
- `.claude/rules/github-actions.md` — GitHub Actions と Dependabot

## テスト

- **Swift Testing**（`import Testing`）を使い、TDD で振る舞いを先にテストにする。
- **テスト名は日本語で振る舞いを書く**: `@Test("12ページの冊子は3枚の用紙になる")`。
- 仕様として書いた制約（面付けの式、用紙寸法など）はテストで固定する。
- WebKit を使うテストは遅く不安定になりやすい。数を絞り、タイムアウトを設ける。Kit の Rendering のテストは、`make test-kit`（`SWIFT_TEST_FLAGS` を指定しないとき）が直列（`--no-parallel`）で走らせる。新しい CI の runner で並列に走らせると、複数件がまとめて時間切れになることがあった（比較では、並列で 10 台中 1 台、直列で 10 台中 0 台が失敗）。個別に走らせるときも、必要なら `--no-parallel` を付ける。
- fixture に個人情報や実データを入れない。

## Git / PR

- `master` は保護されている。topic ブランチ → PR → CI（`build-and-test`）成功でマージ。
- コミットは論理的な最小単位ごと。メッセージは**日本語の Conventional Commits**（例: `feat(print): A5 冊子レイアウトを追加`）。AI と協業したコミットには `Co-Authored-By` を付ける。
- **エージェントは明示的に頼まれない限り commit / push / merge をしない**。
- PR 本文は日本語で、テンプレート（`.github/PULL_REQUEST_TEMPLATE.md`）に沿って書く。
- **見た目や操作が変わる PR には、注釈付きのスクリーンショットを貼る**（テンプレートの「スクリーンショット」の欄）。
  - 撮る: 開発版のスナップショット（`project-surimono-dev` の `-SurimonoSnapshotPath`）で、変えたところが写る状態を撮る。ライト・ダークで見た目が違うものは両方。文書は `Samples/` のサンプルか自分で作った架空のものだけを使い、ユーザーの文書・個人情報・デスクトップを写さない。
  - 注釈: `swift .agents/skills/project-surimono-dev/scripts/annotate-screenshot.swift <入力.png> <出力.png> "x,y,幅,高さ:ラベル" …` で、変えた箇所に赤い枠と番号付きの短いラベルを付ける（座標は画像の左上からのピクセル）。本文では番号ごとに何が変わったかを書く。
  - 置き場: 画像は master に入れず、孤立したブランチ `pr-assets` の `pr-<番号>/` に push して、`https://raw.githubusercontent.com/phyten/surimono/pr-assets/pr-<番号>/<名前>.png` を本文に貼る（`gh` は PR へ画像を直接上げられないため）。`pr-assets` は既存の画像を残して足していく（`stats` のように上書きしない）。
  - 撮れない変更（メニューを開いた状態、実機のホイール操作など）は、撮れなかったことと代わりに確かめたことを書く。

## 開発資料（.docs/）

- `.docs/` はローカル専用（gitignore 済み）。企画書、デザインモック（`.docs/design/`）、メモを置く。
- 公開リポジトリに載せる情報（README、コード、Issue）と混同しない。`.docs/` の内容をコミットやPR本文へ丸ごと転記しない。

## 地雷（ハマりどころ）

- メンテナ環境のグローバル gitignore は `AGENTS.md`・`CLAUDE.md`・`.claude`・`.agents` を無視する。リポジトリの `.gitignore` で打ち消しているので、その行を消さない。
- `Surimono.xcodeproj` は手書き。Xcode の GUI でターゲットや設定を編集すると pbxproj が大きく書き換わる。設定は xcconfig へ。
- 生成する Info.plist（`GENERATE_INFOPLIST_FILE`）は `CFBundleName` を常に `PRODUCT_NAME` にする（`Configs/Info.plist` に書いても `INFOPLIST_KEY_CFBundleName` でも変わらない）。メニューバーのアプリ名は `CFBundleName` なので開発版でも Surimono と出る。Dock・⌘Tab・アクティビティモニタ・ウィンドウの持ち主の名前は表示名（`CFBundleDisplayName`）の Surimono Dev。
- `INFOPLIST_KEY_*` を `[config=Debug]` だけで指定すると、Release の生成 Info.plist にそのキーが空文字で入る（`CFBundleDisplayName` で起きた）。条件なしの値も書く。
- `open -a` は相対パスを受け付けない（アプリの名前として探して失敗する）。`make run` は `realpath` で絶対パスにして渡している。
- 開発版と公開版は同じ書類の種類を `Alternate` で宣言している。他に開けるアプリがない種類では、あとから登録された開発版が既定のアプリになることがある（ダミーのアプリでは、名前・バンドル ID・版・パスの並びによらず、あとから登録した方が選ばれた）。公開版を既定にするには Finder の「情報を見る」→「このアプリケーションで開く」→「すべてを変更」で選ぶ（バンドル ID で覚えるので、開発版と取り違えない）。
- 冊子印刷は短辺綴じが前提。プリンタによっては裏面が上下逆になるため、「裏面を 180° 回転」オプションで補正する。
- WKWebView の印刷は、ビューがウィンドウに載っていないと白紙になる。WebPaginator は非表示ウィンドウに載せ、`runModal(for:)` と別スレッドの印刷で PDF を作っている。
- WebKit の印刷は、ページの余白に背景を描かない（`NSPrintInfo` の余白も、`@page` の余白も。`@page` の背景は効かない）。テーマの紙は別のページに組んで下に敷いている（「紙の地」）。
- WebKit は印刷するとき、ページを用紙の 1.25 倍の幅で組んで縮める（1 CSS px が 0.8pt。`WebPaginator.printPixelsPerPoint`）。それより広い文書はさらに縮む。紙のページの位置はこの比で計算している。
- 根要素の背景色が透明なページには、WebKit が根要素の範囲に白を敷く。CSS では消せないので、本文のページは WKWebView の非公開の `drawsBackground`（`_setDrawsBackground:`）を切って組む（`WebPaginator.drawsClearPages` で有無を確かめ、ないときは紙を本文に残す）。
- 根要素に margin を付けても、繰り返さない背景画像は紙面の原点から描かれる（繰り返す画像は margin の内側から）。紙のページは padding と `background-origin: content-box` で根要素の中身を本文の範囲に置く。
- `body` に透明な部分のあるグラデーションを付けると、`html` にも背景があるとき印刷で黒く塗られた（v0.3.0 の「宿題ノート」）。
- WebKit の印刷は、文書の `@page` の size と margin を NSPrintInfo より優先することがあり、ページの高さを CSS の整数ピクセルで区切る。用紙ちょうどの大きさの紙片を並べた HTML（`@page { size: A4; margin: 0 }` と A4 の `.sheet` など）は、A4 が 1122.52px なので 0.52px はみ出し、1 枚が 2 ページに分かれていた。WebPaginator は用紙と下の余白をともに 2pt 高くして組み、できたページを上をそろえて元の大きさに切り戻す（`pageHeightAllowance`。測った環境では +0.5pt は標準の用紙の大きさに丸め戻され、+1pt で効いた）。文書が `@page` の規則を持つ（余白を上書きしうる）ときは、切り落とす帯を白地に描き、文字・罫・画像・背景など何か描かれたページがあれば切り戻さず、面付けで用紙へ縮めて収める。箱を変えたページは PDFKit が一部の文字の位置を 0 と返すので、切り戻した PDF は書き出して読み直したものを返す（面付けした用紙の PDF でも文字の位置は当てにならないので、テストで見えているかを文字の位置で確かめない）。
- `loadHTMLString(_:baseURL:)` は基準 URL が file URL でもローカルのファイルを読む権限を与えないため、文書の隣の画像が表示されない。WebPaginator は生成した HTML を一時ファイルに書いて `loadFileURL` で読み込む（生成 HTML では JavaScript を止めている）。
- DocumentGroup のアプリでは、open-documents を `application(_:open:)` だけで受けると複数選択が文書コントローラに 1 つずつ渡ることがある。Apple Event のハンドラで一括して受けている。
- 文書なしで起動すると、文書コントローラが「開く」パネルを自動で出す（このパネルの複数選択はルーターを通らない）。`NSShowAppCentricOpenPanelInsteadOfUntitledFile` を false で登録して止め、ウェルカム画面を出している。
- `@FocusedValue` / `focusedSceneValue` は AppKit で開いたウィンドウ（画像の束・ウェルカム画面）に届かない。メニューからは `DocumentWindows.activeModel` を使う。
- `NSHostingController` を `contentViewController` にすると、既定ではウィンドウが中身の理想の大きさまで縮む。`sizingOptions = [.minSize]` にして大きさを指定する。
- ホスト付きテストの中では `NSApp.mainMenu` が組み立て済みなので、メニュー構成（「開く…」が 1 つ、など）をテストで固定できる。
- PDFView は表示モードや文書を切り替えたときにも自分で倍率を変え、ピンチも内部のスクロールビューが先に受け取って自分で拡大する。`PaperPDFView` はピンチとスマートズームをローカルのイベントモニタで PDFKit より先に受け取って自分の倍率（窓に合わせた大きさに対する比）を変え、PDFKit が自分で変えた倍率はいつも窓に合わせ直す（ピンチを PDFKit に任せると、指を離した後に元の大きさへ戻ってしまう。取り違えると何も変えていない文書の設定が保存される）。
- 帯の部品を `ViewThatFits` で丸ごと別の組み立てに切り替えると、中のボタンが作り直され、そこから出したポップオーバーが閉じる（表示の型を変えて窓の幅が変わったときに起きた）。帯は `ViewThatFits` を使わずに測った幅から出す物を決め、表示のオプションのポップオーバーはいつも帯にある「…」から出す。
- `setFrame(_:display:animate:)` のアニメーションは、呼び出しから戻ったあとにライブリサイズの終了を通知する。アプリが窓の大きさを変えるときは `ViewerWindow` を通し、利用者のリサイズと区別する。
- PDFView の `displaysAsBook` は単独の表紙を中央に置くため使わない。表示用コピーに白紙を足し、`ViewPageLayout` で表示ページと論理ページを対応づける。単ページの連続スクロールは `joinsPages`（既定オン）でテーマ付き文書の既知の余白だけを詰める（縦は上下、横は読む向きに沿って接する左右）。HTML は `@page` による余白変更を表示側で保証できないため切り取らない。表示用 PDF は、元の PDF・白紙の位置・切り取る辺と量・番号が同じなら再利用する。表示番号は `AppPreferences.viewPageNumbers`（既定オフ）で印刷番号と別に描き、単ページの連続スクロールと白紙には出さない。元の論理 PDF と印刷・書き出しには影響させない。
- メニューの `.disabled(...)` をキーウィンドウのモデルから作ると、SwiftUI はメニューを開くまで更新せず、ショートカットが効かないままになる。項目は有効のままにして、できないときはモデル側で何もしない。
- DocumentGroup の窓でツールバー項目をすべて消すと SwiftUI はツールバーごと消し、タイトルバーが縮む。ツールバーを自前の NSToolbar に差し替えると SwiftUI の監視でクラッシュする。印刷モードは見えない項目（`PrintModeToolbarPlaceholder`）でタイトルバーの高さを保つ。画像の束の窓では `sceneBridgingOptions = [.toolbars]` で同じツールバーを使う。
- SwiftUI がビューを組み直している最中に、SwiftUI が KVO で監視する窓のプロパティ（`isMovableByWindowBackground` など）を設定すると落ちる（同じ値でも通知される）。`WindowReader` は更新が終わってから窓を渡し、`ViewerWindow.configure` は値が違うときだけ設定する。
- 印刷モードとの切り替えで、表示モードのビュー（`PaperPDFView` を含む）は作り直される。戻したい状態はビューの中だけに持たず、モデルから渡す（読んでいたページは `DocumentViewModel.currentPageIndex` から `PaperView.initialPageIndex` で戻す）。
- PDFKit のアクセシビリティ（VoiceOver や画面を読むアプリ）は、表示したページを保持しないまま後から読みにくる。描いた PDF の一時的な `PDFDocument` からページだけを取り出すと元の CGPDFDocument が解放され、最適化したビルドでは毎回 CoreGraphics の中で落ちた（開発版では落ちにくく気づけない）。取り出すときは `StandalonePage.first(of:)` を使う。紙（`PaperPDFView`）は表示した文書を紙の寿命の間すべて残す（差し替えた古い文書のページも読みにくるため）。確かめるときは、AX の木を読み続けながら見開きと単ページを切り替える負荷を Release 構成のアプリにかける。
- 紙（ページ）はダークでも白い。紙の上に浮かべるパネルにマテリアルだけを敷くと、白い紙の上で中間のグレーになり補足の文字が読めない。`paperOverlayBackground` を使う。
- アドホック署名には Team ID がないため、Hardened Runtime の Library Validation が、埋め込んだ Sparkle.framework を拒んで Release 版が起動時に落ちる（`different Team IDs`）。`Configs/Surimono.entitlements` の `com.apple.security.cs.disable-library-validation` で外している。Developer ID で署名するようになったら消す。Debug は Hardened Runtime が無効なので気づけない。署名や依存を変えたら、`make package` で作ったアプリを起動して確かめる。
- xcconfig では `//` から後ろがコメントになる。URL は `https:/$()/…` と書く（`SURIMONO_UPDATE_FEED_URL`）。
- エージェントのサンドボックス（Codex など）では、LaunchServices（UTType の準拠関係）、testmanagerd（ホスト付きテスト）、WebKit の子プロセス、ホーム配下のキャッシュへの書き込みが拒否されることがある。ビルドだけなら `CFFIXED_USER_HOME` などを `build/` 配下に向ける回避策があるが、Makefile には入れない。テストと起動の最終確認は通常の環境で `make test` / `make run` を実行して行う。

## スキル

`.agents/skills/`（Claude Code からは `.claude/skills/` として同じものが見える）:

- `project-surimono-dev` — ビルド・起動・テスト・目視確認の手順
- `project-surimono-add-format` — 対応形式を追加する手順
- `project-surimono-print-layout` — 印刷レイアウト・面付けの追加と検証
- `project-surimono-release` — リリース手順
