# AGENTS.md — Surimono

このリポジトリで作業する AI エージェント（Codex、Claude Code など）共通の指示。人間向けの案内は [CONTRIBUTING.md](CONTRIBUTING.md)。

## プロダクト

- **Surimono（摺物）**: Markdown / PDF / 画像 / Org / テキスト / HTML / LaTeX を「雑に開いて、雑に見て、さっと刷る」macOS アプリ。主役は印刷。
- 主な機能: 出てくる用紙をそのまま並べる印刷モード（刷り台。画面の語は「印刷画面」）、印刷テーマ（画面の語は「スタイル」。CSS。12 のカテゴリーに 108 種。文書の 1 ページ目の見本を並べたパレットで、最近使った・お気に入り・定番・カテゴリーから選べ、乗せると紙で試せる。4 つまで並べる見比べ台もある）の切替とユーザー CSS・文字の大きさ、スタイルとは別の軸のコードの配色（12 の候補と枠・行番号などのオプション）、HTML のノイズ除去プリセット（ユーザー追加可）とスマート削除（ベータ）、印刷レイアウト（A判と B判（JIS）の片面・両面、中綴じ冊子 A3→A4 / A4→A5 / B4→B5 / B5→B6、2アップ）、紙の仕上げ（上下左右の余白、ヘッダー・フッター、改ページ、紙の目次、書き込むためのノートページ）、刷り台で選んだプリンターへのダイアログなしの印刷（システムの印刷画面も選べる）、PDF 書き出し、紙に帯を重ねない表示モード（上だけ / 上と下に分けるメニュー、常に表示 / ポインタを乗せたときだけ、目次、文書の数字、A判 / B判、見開き / 単ページ、拡大縮小、最前面に固定）、内容のハッシュごとの設定の保存、複数の画像や ZIP の中の画像をまとめた「画像の束」（並び替え・印刷・PDF 書き出し）。外観はシステムの設定に従う（アプリに切替は置かない）。
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
make check-appstore             # Mac App Store 版（ターゲット Surimono App Store）を組み立て、サンドボックスと Sparkle なしを確かめる
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
- 囲み（`MarkdownCallouts`）: 表題を札にし、名前を意味の 4 群へ畳む。情報（note・info・todo・example）は `callout-note`、成功（tip・success）は `callout-tip`、注意（important・warning・question）は `callout-warning`、危険（danger・bug）は `callout-danger`（クラス名は以前のもので、ユーザー CSS のために変えない）。important と example には、以前のクラス `callout-important` を群のクラスの前に併記する。手書きの HTML の `callout callout-important` は注意の見た目になる。ほかに `callout-quote` と無地の `callout-neutral`（neutral・details）。`data-callout` には書いた名前がそのまま残る。
  - 未知の名前は `callout-unknown callout-neutral` で、アイコンの代わりに名前の札（`.callout-name`）を出す。表題を書かなければ名前の見出し語が札の文字になる。Zenn の `:::message`（`alert` も）は、Zenn と同じく表題がなければ札を出さず、枠と地だけの箱にする。
  - アイコンは表題の中のインラインの SVG。CSS の画像では `currentColor` が届かず、テーマごとの札の文字色にならない。
- `:::` は markdown-it-container と同じく、段落・参照定義・引用・リストの続きを打ち切る（コード・HTML・明示的な引用行・字下げしたリスト本文・AST のブロックに属さない行は除く）。
- Markdown の拡張記法（`MarkdownExtensions`、SurimonoCore）: 脚注 `[^id]`、`==ハイライト==`、`^上付き^`、`~下付き~`（pandoc と同じく `~~` は取り消し線）、ルビ `{漢字|かんじ}`・`{漢字|かん|じ}`、絵文字 `:name:`、定義リスト（語の次の行の `: 説明`）、見出しの ID（GitHub と同じ slug、`{#id}` で指定）と目次 `[TOC]`。
  - インラインの記法は、cmark の前に原文を inline HTML へ書き換える。中の Markdown もそのまま読まれ、表の `|` とも混ざらない。コードブロック・HTML ブロック・コードスパン・タグ・リンク先・URL は書き換えない。
  - 脚注は最初に参照した順に番号を振り、本文は末尾の `section.footnotes` にまとめる。紙からは戻れないので、戻りのリンクは付けない。
  - Mermaid: Markdown の ```` ```mermaid ```` と Org の `#+begin_src mermaid` は、原文をエスケープした `.mermaid-block` にする。Rendering に同梱する mermaid.js を隔離された世界 `surimono` で一度評価し、neutral・strict・本文の書体で SVG にしてから、変更の印・紙の判定・印刷前の確認・ページ分割を行う。文書の JavaScript は無効のまま。図のない文書ではライブラリを読み込まない。元の文書のリソースを読み込んだ後、図による追加のリソース取得は遮断する。描けない図や時間内に終わらない図は原文を残し、印刷前の確認に出す。パレットの小さな見本は原文のまま（乗せて試す紙と見比べ台は図になる）。
  - 絵文字の対応表 `Resources/emoji.json` は GitHub の gemoji（MIT）の別名だけを取り出したもの。ライセンス文を `App/Acknowledgements/` に同梱している。
  - 数式 `$…$`・`$$…$$`（複数行も）・`\(…\)`・`\[…\]`・```` ```math ```` は、SwaTex（純 Swift の KaTeX 互換の組版）で SVG にする（`MathRenderer`）。式は cmark の前に取り出し、インラインは私用領域の文字の目印、行をまたぐものは HTML ブロックにするので、強調やエスケープが LaTeX に触れない。インラインの `$` は式に接していて後ろに数字が来ないときだけ（`$5 と $10` は文字のまま）。字形は KaTeX の書体の `<text>` で、使った書体だけを本文の最後の `<style>` に data URL の `@font-face` で埋め込む（文書の隣のファイルを読まずに刷れる。テーマの「Web フォントを使わない」とは別で、アプリが同梱する数式用の書体）。大きさは em（文字の 1.1 倍）、色は `currentColor` でテーマに従う。読めない式は原文を `.math-error` で残す。
- LaTeX（`.tex`・`.latex`・`.ltx`、UTType `org.tug.tex`）は `LaTeXConverter`（SurimonoCore）が HTML 断片にする。TeX エンジンではなく、よく使う部分集合を読んで印刷テーマで刷る（Swift で書かれた TeX エンジンはなく、Tectonic などは TeX Live の同梱とネットからの取得が要るため）。
  - 読むもの: 前置きの `\documentclass`・`\title`／`\author`／`\date`・`\newcommand`／`\def`・`\DeclareMathOperator`・`\definecolor`・`\graphicspath`、`\maketitle`、abstract、`\tableofcontents`、番号つきの節（章のある文書クラス、`\appendix`、和文の文書クラスは「第1章」）、`\label`／`\ref`／`\eqref`、書体とサイズ、itemize／enumerate（enumitem の `label=`・`start=`）／description、quote・center など、verbatim・lstlisting・minted（色付けは `SyntaxHighlighter`）、`\verb`、数式（`$`・`\(`・`\[`・equation・align などは SwaTex。星なしの環境に式番号）、`\footnote`、hyperref の `\href`／`\url`、xcolor、figure／table の `\caption`（図と表は別の番号）、graphicx の `\includegraphics`（拡張子がなければ文書の隣と `\graphicspath` を探す）、tabular（列の揃え・縦線・`\hline`・booktabs・`\multicolumn`・`\multirow`）、amsthm の `\newtheorem`（節ごと・共有・番号なし、`\theoremstyle`。和文の文書は plain でも斜体にしない）と proof、thebibliography と `\cite`（natbib の `\citep` なども番号で）、siunitx の `\num`・`\qty`（`\SI`）・`\unit`（`\si`）・`\ang`（数式の中でも使える）。
  - 前置きの `\newcommand` は文章の中では展開し、数式には定義として渡す（SwaTex が読めない定義は外す）。知らないコマンドは名前を捨てて引数の文字を残し、設定だけのコマンド（`\setlength` など）は引数ごと消す。geometry は無視して Surimono の用紙と余白を使う。TikZ などの図と `\input`・`\bibliography`（.bib）は、描けない・読まないことを枠で示す。
  - 改行をはさんだ和文の文字の間には空白を入れない（和文の TeX と同じ）。参照・文献の番号・目次は文書の終わりまで読んでから埋める。`\bibitem` のない `\cite` はキーを太字で出す。
- JavaScript: Markdown / Org / テキスト / CSV / LaTeX から作る HTML では、文書の JavaScript は常に無効。HTML 文書は設定（既定は許可）とプリセットの両方が許すときだけ有効。組み込みテーマの飾りと Mermaid の描画スクリプトは例外で、組版の準備としてアプリの隔離された世界（`world(name: "surimono")`）で走り、文書のスクリプトとは混ざらない。
- 印刷テーマの目録は `Resources/themes.json`（SurimonoCore）: カテゴリー（順と名前）、定番の順、各テーマの id・英語名・日本語名・カテゴリー・飾りのスクリプトを持つ。テーマの CSS は `Resources/<id>.css` で、`common.css` の後に重ねる（`PrintThemeLibrary`）。メニューの並び（最近使った 5 つ・お気に入り・定番・カテゴリー・自分のスタイル）は純粋な型 `PrintThemeMenu` が決め、テストで固定している。
  - テーマを足すときの決まり: `@page`・CSS の段組み・`position: fixed`・アニメーション・外部の URL・Web フォントは使わない。書体は macOS に入っているものだけで、最後に日本語の書体と総称の書体を置く。例外として、アプリが同梱する KaTeX の書体を `ThemeFonts`（SurimonoCore）の名前 `"Surimono Computer Modern"`・`"Surimono Computer Modern Typewriter"`（引用符つき）で使える。使ったスタイル（ユーザー CSS も）にだけ、欧文の範囲に絞った data URL の `@font-face` がスタイルの要素に入る（パレットが要素を差し替えても書体が付いてくる）。数式の書体とは別の名前で欧文の範囲に絞るので、和文や … ・矢印はこの書体を使わず、テーマの書体の並びで次の書体に任せる（「LaTeX 風」テーマが使う）。パレットは要素を差し替えたあと、書体の読み込みを待ってから見本を描く。見出しに CSS のカウンターで番号を振るときは、`body:not(.format-latex)` を付けて LaTeX の文書を外す（LaTeX は自分で番号を持つ）。紙の地は白かごく淡い色にする（インクを使い切らないため）。本文は 4.5:1 以上のコントラストにする。
  - 紙の色や模様は `html` に書き、`body` の背景は `transparent` にするか `html, body` で同じ色にする（`body` の背景は本文の範囲にしか出ない。テストで固定している）。模様は SVG の画像か放射状のグラデーションで描く（固い境目の線形グラデーションを `background-size` で並べると、WebKit の印刷で細い横縞になった）。1 本だけの縦線は `repeat-y` にする（横にも並ぶと右の余白に 2 本目が出る）。
  - 囲みの色は `common.css` の `:root` が受け口で、テーマは `--callout-info`・`--callout-success`・`--callout-warning`・`--callout-danger`・`--callout-plain` と、紙に色があれば `--callout-paper` を渡すだけで、地（`--callout-tint-amount` の割合で紙に混ぜる）と札が揃う。ほかに `--callout-frame`（枠の太さ）・`--callout-radius`・`--callout-tag-radius`・`--callout-title-weight`。枠のない札は `.callout` で `--callout-tag-fill` と `--callout-tag-ink` を変える。4 群は線の種類（実線・点線・破線・二重）でも分かれるので、一色のテーマでも種類が残る。札の文字・本文・引用の表題の 4.5:1 は全テーマ `CalloutThemeTests` で確かめている。
  - 枠と地は `.callout::before` に描き、札は上半分がその線に重なる通常の流れの要素にする。`.callout` の上の padding を足さない（札が線から離れる）。札を `.callout` の箱の外へ出すと、改ページやページの上端で札が切れる。
  - 飾りのスクリプト（`decorations.js`）は、テーマの `--deco-emoji` から絵文字を選び、見出し・箇条書き・区切り線に `data-deco` を付ける。乱数の種は本文の文字から作るので、同じ文書なら画面と印刷で同じ絵柄になる。テーマの CSS が `attr(data-deco)` で見せる。
- 紙の地: テーマが `html` に白以外の背景（色・画像）を付けていれば紙とみなす。WebKit は余白に背景を描かないので、本文のページは紙を外すスタイル（`PaperBackground.removalStyle`。最初から文書に入れる）と下地なし（`drawsBackground: false`）で組み、紙だけのページ（根要素の中身を本文の範囲に置いた空の文書。`PaperBackground.document`）を余白なしで別に組んで、`PaperComposer` で各ページの下に敷く（リンクも付け替える）。模様は本文の左上を起点にそろい、余白にも続く。横にはみ出して縮む文書だけは紙を本文に残す（余白は白のまま）。パレットの見本も同じ組み方で、余白を含む論理ページ全体を描く。

- コードの配色（`CodePalette`、目録は `Resources/code-palettes.json`）はスタイルとは別の軸で、スタイルを変えても残る。文書ごとに `DocumentSettings.codePaletteID`、既定は `AppPreferences.defaultCodePaletteID`。`match`（スタイルに合わせる）は配色なしで、テーマの `--hl-*` をそのまま使う。重ねる順は common → テーマ → コードの配色と枠（`CodeStyle`）→ 文字の大きさ。既定の `CodeStyle` はスタイルシートも本文も変えない。HTML 文書には効かない。
  - 配色を足すときの決まり: 15 個のトークンすべてに色を持ち、地を持たない配色は `lightGrounds`（白・淡い地・最も濃いテーマの地）の上で、地を持つ配色は自分の地の上で 4.5:1 以上にする（`CodePaletteTests` が全配色の全トークンを見る）。`inkIndex` は標準テーマを 100 としたインクの量で、300 以上の配色は `inkHeavy` にして候補から外し、選ぶと注意を出す。
  - 枠のオプション（`CodeBlockOptions`、文書ごとに `DocumentSettings.codeBlock`）: 何がコードのブロックかは `CodeBlockMarkup` だけが決める。組み上がった断片の属性のない `<pre>` に `code-block` の印と `<code>` を足し、スタイルシートと `CodeFitScript` はこの印を見る（`pre.surimono-plain` などは別物）。行番号と切る印の行の要素、言語名の札も同じ所で足す。長い行の「縮める」「切る印」はテーマの書体と余白で幅が決まるので、`CodeFitScript` が組版の準備としてアプリの隔離された世界で測る。WebKit の印刷は web view の 1.25 倍の幅で組むので、`WebPaginator.printPixelsPerPoint` を掛けた本当の組版の幅に広げて測り（web view の幅は丸めてあり、根の `zoom` の分も割り戻す）、見本は 1 倍で測る。テーマの判定が結果を返すので、準備の台本ではテーマの部分を最後に置く。
- 論理ページ寸法: 通常は用紙そのもの。冊子と 2アップは用紙の半分（A3 → A4、A4 → A5、B4 → B5、B5 → B6）。Web 系の文書は論理ページ寸法で組版し直し、PDF と画像は縮小して収める。
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
- アプリの既定値（既定のレイアウト・余白、表示の型・ページ送り・読む向き・スクロール方向・表紙、窓を開いたときの最前面とメニューの固定、文字の大きさ・用紙の向き）と、スタイルの最近使ったもの・お気に入り（アプリ全体）は `AppPreferences` が `UserDefaults` に保存する。スタイルを選んだと記録するのは利用者がメニューで選んだとき（`DocumentViewModel.selectTheme`）だけで、復元・既定に戻す・代わりのテーマへの切り替えでは記録しない。ユーザー CSS とユーザープリセットは `~/Library/Application Support/Surimono/` 配下の `Styles/`（*.css）と `Presets/`（*.json）に置く（`UserLibrary`。Debug ビルドは `Surimono Dev/` 配下）。
- 文書ごとの設定（表示の型・向き・送り方・表紙・拡大率・窓の大きさ・帯の出し方・紙の判・印刷レイアウト・スタイル / プリセット・文字の大きさ・印刷のオプション・画像の並び順）は `DocumentSettings` にまとめ、**ファイル名ではなく内容の SHA-256（`ContentHash`）をキーに** `~/Library/Application Support/Surimono/DocumentSettings/`（`KeyedRecordStore`。Debug ビルドは `Surimono Dev/` 配下）へ保存する。
  - キー: 1 ファイルはその内容、ZIP は ZIP ファイル自体、画像の束は各画像のハッシュを並べ替えて作る集合のハッシュ（`ContentHash.imageSet`。書式は永続化の形式なので変えない）。合本は子の内容のハッシュを並べ替えた集合のハッシュ（`ContentHash.binderSet`、別の接頭辞）を使う。並び順はそれぞれ `imageOrder`・`binderOrder` にハッシュの列で保存し、合本の「各文書を表面から始める」は `binderStartsOnFront` に保存する。
  - 復元のトーストは出さない。表示のオプションの最下段は、保存した設定があるときに「この文書の設定を使っています」と「既定に戻す」を出し、ハッシュは見せない。保存した設定がなければ状態の文言は出さず、「既定に戻す」は無効のまま表示する。
  - 保存は利用者が何かを変えたときだけ（`DocumentViewModel` が読み込み・復元・既定に戻した時点の値と比べる）。開いている間にファイルが変わったら、表示中の設定を新しいハッシュへ引き継ぐ。
  - 保存した印刷レイアウトは刷り台と出力だけに効く。表示モードと見比べ台は常に A4 片面で組み、向き・余白などは共有する（PDF・画像は向きが自動なら元のページを保つ）。

- 印刷設定セット（`PrintSettingSet`、SurimonoCore）は、名前を付けて別の文書へ当てる設定。レイアウト・用紙の向き・余白・印刷のページ番号と、保存した形式に応じたテーマ・文字の大きさまたは HTML プリセットだけを持つ。表示設定・スマート削除・裏面の回転は含まない。`AppPreferences` の `printSettingSets` に JSON 配列として作成順で保存し、読めない要素だけを除く。適用できない形式の項目と消えた ID を飛ばし、同じ項目で一致を判定する。適用は利用者の変更として文書ごとに保存するが、最近使ったスタイルには記録しない。刷り台・表示のオプション・表示メニューは `SettingSetMenu` を共有し、設定画面で名前変更・削除を行う。

## ウィンドウとファイルの開き方

- **1 つの刷り物（1 ファイル、画像の束、または合本）= 1 つのウィンドウ**。表示中のウィンドウにドロップしても置き換えず、新しいウィンドウで開く。すでに開いているファイルは前面に出す。
- ユーザーがファイルを選ぶ・渡す・ドロップする経路は、標準メニューの「最近使った項目」を除いて `OpenRouter`（App）を通す。分類は `OpenRequest`（SurimonoCore）:
  - 1 つ → 文書として開く（DocumentGroup / `NSDocumentController`）
  - 2 つ以上ですべて画像（種類の混在は可）→ 画像の束（ファイル名の自然順）
  - 2 つ以上で画像以外を含む → ファイル名の自然順の合本（Markdown / Org / テキスト / CSV / LaTeX / HTML / PDF / 画像）。ZIP・フォルダー・未対応形式は除き、引き出しで知らせる。除外後に画像だけが残れば画像の束で開き、既存のトーストと引き出しで除外を知らせる。対応する文書が 1 つもなければ警告（ドロップならその窓のシート）
- 経路ごとの入口:
  - Finder / Dock / 「このアプリケーションで開く」: `AppDelegate` が open-documents の Apple Event を受ける（`applicationWillFinishLaunching` で登録）
  - ファイル > 開く…: 標準の項目が送る `openDocument:` を `AppDelegate` が受ける（SwiftUI の AppDelegate が応答チェーンで転送する）。独自の「開く…」をメニューに足さない（標準の項目と重複し、標準の側は文書コントローラが 1 つずつ開いてしまう）
  - ドロップ: 文書・画像の束・ウェルカム画面の `.dropDestination`
  - 最近使った項目: 標準メニューの項目は文書コントローラが 1 ファイルを開く（規則と同じ結果になるので、ルーターを通さないままでよい）。ウェルカム画面の最近使ったファイルは `OpenRouter` を通す
- クリップボードは「ファイル > クリップボードから開く」（⌘N）とウェルカム画面から開く。ファイル URL は `OpenRouter` へ渡し、文字列（Markdown / テキスト / HTML の推定）・PNG / TIFF は `ClipboardContent` で判定し、`ClipboardWindows` が原文の一時ファイルを作らずメモリから開く。同じ内容の窓は前面へ出す。画像の束と `MemoryDocumentWindowController` を共有し、最近使った項目には載せない。
- サービス（「Surimono で開く」「Surimono で刷る」）は `Configs/Info.plist` の `NSServices` で宣言し、`ServiceProvider` が受ける。選んだ文字（RTF は文字にする）は `OpenRouter.open(_:printing:)` から `ClipboardWindows` の同じ窓の仕組みでメモリから開き、ファイルは `OpenRouter` の規則で開く。刷る要求は対象の窓だけに結び付ける。合本・画像の束は開く処理が返すモデルへ、単独の文書は窓ができたときに `fileURL` が同じモデルへ渡す（同じファイルを含む別の窓は受け取らない）。新しい窓は初回の組版と窓の大きさの調整のあとで刷り台へ入る（`requestPrintMode`。先に入ると窓が紙の形にならない）。項目名と窓口（`NSPortName`）は `SURIMONO_SERVICE_APP_NAME` で開発版と公開版を分け、`NSRegisterServicesProvider` で同じ名前を登録する。訳は `App/ServicesMenu.xcstrings`（キーは英語の項目名で、開発版の名前も持つ）。`NSRequiredContext` を消すとメニューに出なくなる。開発版を試すときは `lsregister -f <App>` と `pbs -update` のあと、`NSPerformService` か `pbs -dump` で確かめる。
- 「ファイルとして保存…」（`DocumentViewModel.saveAsFile`）は、メモリ上の文書（クリップボード・サービス・ストリーミング）にだけ、ファイルメニューと帯の「…」と刷り台に出す。保存パネルで選んだ場所へ新しいファイルを書くだけで、窓はメモリ上の文書のまま。`DocumentEditMenu` が隠す NSDocument の保存の項目とは別の項目にする。
- Markdown の親ファイル: `MarkdownIncludes`（SurimonoCore）が、行に単独の `<<[file]`・`{{file}}`・`/file` と、見出し・区切り線・リンクだけのリストでできた文書（SUMMARY.md の形。ファイル名は問わない）を読む。`{{…}}` と `/…` は拡張子があるときだけ。コードブロックの中は読まない。パスは親の隣から相対で、絶対パス・URL・親のフォルダーの外へ出る `..` とシンボリックリンクは読まず、見つからないファイルと同じく引き出しに示す。親が名指しした子は、読むたびに `ConfinedFile`（SurimonoCore。`LocalResourceSchemeHandler` と共有）で、計画のときの親のフォルダーの実パス（`Plan.root`）の下にあることを開いた記述子の実パスで確かめ、その記述子から読む。再読み込みの前に子や途中のフォルダーがリンクへ差し替えられても外を読まない。利用者が足した文書は制約しない。本文には差し込まない（開いた文書は原文のまま刷れる）。読める文書が 2 つ以上あればトーストと「文書」メニューの「合本で開く」で誘い、親の窓を合本の窓に入れ替える。合本は親の本文（インクルード行を除いたもの）を前書きにして並びの順に続け、1 段だけ読む（子の中の記法は読まない）。並びの順のままなら順序を設定に記録せず、「既定に戻す」は並びの順へ戻す（`BinderModel.isInStartingOrder`・`resetOrder`）。窓の再利用は URL の集合と生まれ（`BinderModel.Origin`）の両方が同じときだけ。サンドボックスではフォルダーを許可するまで隣を確かめられないので、書かれた数で誘い、押したときに許可を求める。
- ストリーミングプレビュー（ファイル > ストリーミングプレビュー）は Marked と同じ名前付きペーストボード `mkStreamingPreview` の `public.utf8-plain-text` を読む窓で、1 つだけ開く。`StreamingPreviewWindows` が窓の開いている間だけ 0.5 秒ごとに `changeCount` を見て `DocumentViewModel.replaceContent` でメモリ上の文書を組み直す。組版中の変更は読まずに残し、終わってから一番新しい文字を読む。`changeCount` が増えるのは `clearContents` のときだけで `setString` では増えないので、本文が取れたときだけ既読に進める。文書の設定は保存しない。Marked の基準 URL は使わない（別のアプリの指定でローカルのファイルを読まないため）。
- 画像の束は NSDocument ではなく、`ImageBundleWindows` が AppKit の NSWindow に SwiftUI の `DocumentContent` を載せて開く。メニュー操作は `DocumentWindows.activeModel`（キーウィンドウのモデル）に届ける。
- 合本は `BinderWindows` が `MemoryDocumentWindowController` で開き、`DocumentViewModel.binder`（`BinderModel`）が子と並び順を持つ。引き出しで追加・ドラッグ / ⌥⌘↑↓による並べ替え・取り除き・名前順を操作する。追加は末尾、読み取り・組版に失敗した子は除いて一覧に示す。監視はせず、再読み込みで子と隣のリソースを読み直す。子のフォルダー許可は `FolderAccess` の lease を窓が保持する。合本の保存ファイルは作らない。
- `DocumentSource.binder` は子の `DocumentSource` の配列。`DocumentRenderer` が子ごとの renderer で論理ページを作り、安全にコピーして結合し、既存の面付けへ渡す。子の比較は内容のハッシュ・URL・形式・リソース許可で行い、並べ替え・取り除き・表面開始だけなら子の組版を再利用する。テーマと文字サイズはテーマ形式、プリセットは HTML に適用する。印刷設定セットの適用・一致判定も子の形式の集合で決める。自動の出力方向は、白紙を除いた子の論理ページの多数決（同数なら先頭）で決め、冊子は固定方向を保つ。HTML の子は再読み込みまで保持した原文のバイト列から組版し、本文と集合ハッシュを一致させる。相対リソースは元の文書 URL とフォルダー許可で読む。`BinderPagination` は表面開始がオンのとき、次の読める子が奇数ページから始まるよう文書間だけに白紙を足す。`PrintIssue` は白紙を含む先頭オフセットを加え、ID と原文の鍵に子の識別子を付ける。表示は他の文書と同じく A4 片面。
- ZIP は 1 つのファイルとして DocumentGroup で開き、中の画像を `ZipArchive`・`ZipImageSelection`（SurimonoCore）で集めて `ImageBundleModel` の束にする。ディスクへ展開せず、メモリ上で必要なときに 1 枚ずつ展開する。開いた枚数のトーストは、画像以外を除いたなど `excludedSummary` が空でないときだけ、除いたものと一緒に出す。
- 新しい「開く」経路を足すときは `OpenRouter` を通し、`OpenRouterTests` にケースを足す。

## HTML のスマート削除（ベータ）

- 選んだプリセットのあとに、本文でない部分（広告・おすすめ記事・SNS ボタン・Cookie バナー・追従ヘッダー・ニュースレター欄・ポップアップ）を見つけて消す。判定は組版の準備スクリプトとして WKWebView の中だけで行い、外には何も送らない（`SmartRemovalScript`、SurimonoCore）。
- 本文の領域を 1 つに絞り、本文とその祖先、本文らしい見出しと段落の塊は消さない。候補の識別子は同じ HTML なら毎回同じで、「残す」の選択に左右されない。
- アプリは `RenderSettings.smartRemoval`（HTML のときだけ）で頼み、`RenderResult.smartRemovalCandidates` で候補を受け取る。確かめている間は消さずに点線の枠で示す。オンかどうかと「残す」の一覧は、文書ごとの設定として内容のハッシュで覚える。
- 削除後のトーストは出さず、消した数は確かめるパネルに出す。確かめるパネルは表示モードにだけある。「…」と刷り台のメニューから `reviewSmartRemoval()` で開き、刷り台からなら表示モードへ戻る。枠つきのページは出力に使わない（`canOutput` が偽）。印刷モードに入ると確認を終え、確認中の印刷と PDF の書き出しは、確認を終えて枠のないページができてから行う。

## 印刷前の確認

- 読めない画像、本文より幅の広いブロック、数式と Mermaid の図のエラー、LaTeX の未対応部分を、ページと直し方付きで刷り台の藍の「確認 N 件」に出す。問題がない文書では札も表示モードのメニュー項目も出さず、印刷を止めない。HTML はローカル画像だけを対象とし、PDF・画像・画像の束は対象外。
- 組版の準備で問題の要素に不可視の `surimono-issue:` リンクを置き、PDF のリンク注釈から論理ページと矩形を取得する。未知の ID も含めて注釈をすべて除去してからキャッシュ・面付けへ渡す。void 要素と SVG は隣、表は最初のセルに置く。準備スクリプトは既存の戻り値を関数内に閉じ、問題一覧と一緒に JSON で返して紙の判定・スマート削除の結果を保持する。
- 幅は要素も本文の内側も zoom 後の座標で比較する。問題は検出順の ID とは別に原文の出現箇所の鍵を持つ。「そのページへ」は表示モードの組版を待って同じ鍵の問題へ移り、表示では問題がなくなった場合は文書内の位置の割合で近似する（A4 片面の刷り台からは元のページ番号を使う）。
- 開発用スナップショットは `-SurimonoPopover issues` で刷り台と一覧を開く。確認用の文書は `Samples/preflight.md`。

## 印刷モード（刷り台）

- 表示・見比べ台からの印刷と PDF 書き出しも、まず刷り台に入り、保存した印刷レイアウトの組版ができてから出力する。
- 表示モードの「印刷…」・⌘P で入り、Esc・「表示に戻る」で戻る。印刷モードの朱の「印刷」と ⌘P は、刷り台で選んだプリンターへダイアログなしで送る（プリンターはアプリ全体で `AppPreferences.printerName` に覚え、外されていればシステムの既定。1 台もないときと、刷り台に出ていたプリンターが印刷の直前に外されていたときは、別のプリンターへ黙って送らずにシステムの印刷画面を開く。判断は `PrinterList.request`）。システムの印刷画面は ⌥⌘P と、プリンターのメニューの「システムの印刷画面で印刷…」から。⌘1〜⌘6 はレイアウトを選んで印刷モードへ。モードはウィンドウごと（`DocumentViewModel.mode`）。印刷の順番（後ろの紙から／前の紙から。既定は後ろの紙から）はプリンター名ごとの `PrinterProfile.pageOrder` に覚え、`PrintJobFactory` が印刷設定の `OutputOrder`（Reverse / Normal）に毎回明示する（プリンター任せにしない。両面の表裏の組は印刷システムが保つ）。刷り台の用紙と PDF の書き出しの並びは変えない。
- 裏面の 180° 回転はプリンター名ごとの `PrinterProfile` に長辺／短辺とじを別々に覚える。出てくる順とともに `AppPreferences.printerProfiles` の JSON に保存し、刷り台で選んだプリンターに合わせて切り替える。未設定の値だけ `rotateBack`・`printPageOrder` の既定値を使う。回転は描画時の `effectivePrintOptions` に合成し、古い文書の回転値は無視し、新しい文書設定には書かない。「既定に戻す」や印刷設定セットはプリンターの値を変えない。
- プリンターのメニューの「両面のテスト印刷…」は両面レイアウトで使える。`DuplexTestRenderer` がその用紙の縦向きの表・裏 2 ページを、回転なしで作り、同じ綴じ方で紙 1 枚を送る。送り先の確認は通常の印刷と同じ `PrinterList.request`・`PrintJobFactory` を使い、送り先がない・外れていたらシステムの印刷画面へ。送信後のシートで「上」なら回転なし、「下」なら回転ありを、実際のプリンターとテスト時の綴じ方へ保存する。「あとで」・送信のキャンセルは保存しない。印刷画面で綴じ方を変えたときは再テストを案内する。テストでは送信を差し替え、実際のプリンターには送らない。
- 入るときに `PrintModeWindow` は今の窓を保ち、760×560pt に満たない寸法だけ最小まで広げる（画面の見える範囲が小さければその範囲まで。既存の寸法は縮めない）。戻るときは、自動で広げた場合だけ `PrintModeWindow` が元の枠へ戻す。続いて `DocumentViewModel` が `sizeWindowToPaper(keepHeight: true)` で、その高さを保って幅を現在の紙の形に合わせる。自動で広げていなければ、刷り台で利用者が選んだ高さを保つ。刷り台で印刷レイアウトを変えた場合も、新しい紙の形に合わせる。サイズ変更は `ViewerWindow` を通す。表示モードの縦横比の固定は入るときに外し、戻ってから付け直す。
- 刷り台は面付けした PDF（`sheetDocument`）の各面をベクターのまま描く。拡大率 1 は、1 枚の紙（見出しとラベル込み）が表示領域の幅と高さの両方に収まる大きさ（`TrayMetrics`）で、入ったときに紙の全体が見える。用紙ごとのまとめ方・見出し・ラベルは純粋な型 `PrintTray` にあり、テストで固定している。冊子は「折ってみる」で、読む順にめくって確かめられる。
- 配色は案 C の和紙・墨・朱・藍（`PrintPalette`。ダークでは夜の色）。朱は表示モードの「印刷…」と刷り台の「印刷」の 2 つのボタンだけに使う（入口は「…」付き、送るのは付かない）。

## 紙の仕上げ

- 画面の語とコードの語は分けて持つ: ツールバー（帯・band）、印刷画面（刷り台・tray）、印刷の設定（紙の仕上げ・finish）、目次ページ（紙の目次）、ひな形（note preset）、スタイル（印刷テーマ・theme）、用紙サイズ（判・series）、文書の情報（文書の数字・figures）。この文書の説明はコードの語で書く。
- 入口は 2 つ。刷り台のバーの上の行（`PrintFinishStrip`）に簡易の選択と「すべての印刷設定…」、それで刷り台の右に開く `PrintFinishSheet`（題は「印刷の設定」で上端に固定）に全部がある。行の項目はいつも「項目名 現在値 ▾」のメニューで、窓の幅で別の部品に変えない。入らない幅では 2 行に折り返す。メニューの末尾の「すべての設定で開く」は `presentFinish(_:)` でその節へ直接開く。シートにしないのは、紙を見ながら変えるため。節の順は 用紙と余白 → ヘッダー・フッター → 改ページ → 目次 → ノート → プリンターとの調整（`PrintPrinterOptions`。出力順と裏面の回転）。既定はすべてオフで今の刷り上がりと同じ。例外は、原文の 4 つの改ページ記法（`<!--BREAK-->`・`<!-- pagebreak -->`・`\newpage`・`{::pagebreak /}`）で、既定で読んでその位置で改ページする（依頼で決めた例外。切れば何も出ない）。
- 「この印刷設定を新しい文書にも使う」（`setFinishDefaults`）はシートの下端に置く。余白・ヘッダー / フッター・改ページ・目次だけを保存し、ノートは含まない（help に書く）。新しい文書のヘッダーは `AppPreferences.defaultFurniture`（`PageFurniture`）で、設定画面も同じ値を選ぶ。旧 `pageNumbers` と `PrintOptions` の `showsPageNumbers` の記録は読むときに移すだけ。
- ヘッダーの入力欄は「内容を指定…」のときだけ出す。欄が空でも選んだままに見せるため、`DocumentViewModel.isWritingFurniture` で覚える（`furnitureChoice`）。
- 持ち方: 余白とヘッダー・フッターは `PrintOptions`、改ページと目次は `PrintFinish`（`RenderSettings.finish`・`DocumentSettings.printFinish`）。ヘッダーを変えても組版し直さず、面付けだけやり直す。`PrintFinish` はテーマを使う形式の 1 文書だけに効き、合本には渡さない。
- 余白は `PrintOptions.margins`（`PageMargins`）。1mm 単位で 0〜40。古い `marginsInMillimeters`・`showsPageNumbers` の記録は `PrintOptions` と `PrintSettingSet` の decode で読む。内側・外側は、組版は同じ幅のまま、偶数ページの中身を `PaperComposer.compose(_:paper:shift:)` で横へ動かす（紙の上の位置だけが変わる。`PDFPage.setBounds` で箱をずらしても、書き出すと媒体の箱が戻るので使えない）。`margins.left` が綴じ側（1 ページ目の左）。
- ヘッダー・フッターは `PageFurniture`。描くのは `PDFComposer`（`PageFurnitureDrawing`）なので全形式で効く。「番号」プリセットは今までのページ番号と同じ場所に同じ大きさで出す。足した白紙（`PageFurniture.Context.blankPages`）には入れない。日付は描く日の今日で、`SheetKey` に文字列で入る。
- 見出しの改ページは `PrintFinish.styleSheet` の CSS で、テーマの後の `<style id="surimono-finish">` に入る。最初の見出しと見出しの直下の見出しでは改ページしない。原文の改ページの直後の見出しにも `break-before: auto` を当てる（WebKit は `break-after` と次の `break-before` を別々に数え、白紙が 1 枚できる）。
- 右ページからは、CSS で改ページしてから `DocumentOutline.pages(of:inPageTexts:)` で章のページを探し、`FinishedPagePlan` の通りに白紙を差す。両面と冊子だけ。`DocumentRenderer.finished` が文字の文書の論理ページの列を組み替える場所で、紙（`PaperComposer`）を重ねる前に通る。列の順は `FinishedPagePlan` が決め、面を足す物はここに足す（ノートページの差し込みは「ノートページ」の節）。
- 紙の目次（先頭に足す）は、目次だけの HTML を同じテーマ・用紙・余白で組む。番号は目次のページ数で変わるので、1 ページと仮定して組み、ページ数が違えば組み直す。章は一番大きい見出しで、題名が 1 つだけのときは次の大きさを章にする。原文の `[TOC]` は既定で隠す。
- Markdown の改ページの記法（`MarkdownPageBreaks`）は、単独の行だけを読む。`MarkdownExtensions.protection` と同じく AST の領域で、コードブロック・HTML ブロック（`<pre>` や複数行のコメントの中）・複数行のコードスパンと inline HTML を除く。読んだ行は HTML コメントの目印に置き換えて `<div class="page-break" data-syntax="…">` にする。コメントはその行で終わり段落も切れるので、他の行の意味も行番号も変えない。`common.css` が改ページし、切った記法だけを `PrintFinish.styleSheet` が打ち消す。
- 表は `common.css` の `break-inside: avoid` で、1 ページに入るものはもともと分かれない（実測）。「表を途中で分けない」はそれより長い表の行を分けないだけ。
- レイアウトのカードは上に結果、下に用紙を書く（`PrintModeText.cardTitle`・`cardPaper`。冊子は名前が用紙の半分になるので「A5 の冊子 / 用紙：A4・両面」）。要約は仕上がりの内訳（本文・目次・ノート・白紙）と使う用紙に分ける（`finished`・`paper`）。切替は左に固定し、カードは左から並べる。
- `PrintLayout.presets(in:)` が判ごとのカードの順で、⌘1〜⌘6 もこの順。B判に 3枚＋メモはなく、⌘6 は A4 3枚＋メモのまま。判の切替は同じ位置のカードへ移り（`counterpart(in:)`）、`AppPreferences.paperSeries` に覚える。既定のレイアウトのままの文書では覚えた判のカードを出す。用紙は変えない。
- 組み込みの設定セットは `PrintSettingSet.builtIns(language:)` で、保存しない（id だけ固定）。

## ノートページ

- 書き込むための線のページを本文の間に入れる。刷り台の行の「ノート」と `PrintFinishSheet` の「ノートページ」の節で選ぶ。既定はオフ。全形式で効くが、合本と 3枚＋メモには入れない（`NotePages.applies(to:)`・`offersNotes`）。紙に入れる物なので、表示モードと見比べ台の紙には入れない（`renderSettings` は `mode == .print` のときだけ `notes` を載せる）。出力は刷り台を通るので必ず入る。
- 持ち方: `NotePages`（オン / オフ・入れ方・元のプリセットの id・線の `NotePaperStyle`）を `RenderSettings.notes`・`DocumentSettings.notes`・`PrintSettingSet.notes` に持つ。文書の記録には既定と違うときだけ書く。刷り台で保存する設定セットと組み込みのセットは必ず `notes` を持ち（オフでも）、当てるとノートも揃う。`notes` のない古いセットはノートに触らない。「この印刷設定を新しい文書にも使う」はノートを含めない（新しい文書のページ数が勝手に増えないため）。自分のプリセットは `AppPreferences.notePresets`。組み込みは保存しないので上書きできない。使っていたプリセットを消しても文書の線は残る。
- 入れ方は 4 つ（`NotePagePlan.Placement`）。見開きの片側と両面の裏は、本文がいつも同じ奇偶のページに並ぶようにノートを足すので、右ページ始まりの白紙は入らない。目次は本文の前に置き、足りないときだけノートで揃える。章の終わりは本文の後ろへ足し、次の章の右ページ始まりは足したあとの位置で数え直す。章は目次と同じ `DocumentOutline.chapterLevel`。章の頭がページの途中なら、そのページを前の章の終わりとする（`chapterEnds`）。PDF はしおりの一番上の階層、HTML は見出し、画像は章なし。章がなければ最後に 1 ページ。
- 差し込みは 2 段。文字の文書は `finished` がノートの位置も含めた `FinishedPagePlan` で目次の番号と白紙を決め、ノートの面は入れないまま `FinishedPages.plan` に計画を残す。すべての形式で、`DocumentRenderer.noted` がキャッシュの論理ページの複製にノートを差し、`Logical.noted` に覚える。線だけの変更は WebKit を通らず（`logicalRenderCount` は増えない）、入れ方の変更で組み直すのは文字の文書だけ。キャッシュの論理ページ自体は変えない。
- 内側・外側の余白はノートのあとの奇偶で決まる。文字の文書は `finished` が `FinishedPagePlan` の位置で透明な本文だけを動かし、そのあとで紙を敷くので、紙は用紙に固定のまま。ほかの形式は `noted` の最後に本文のページだけ動かす（`mirrorsLaidOutPages`）。ノート自身の余白は `NotePaperStyle` のもの。
- ヘッダー・フッターは `PageFurniture.Context.blankPages` にノートの面を加えて入れない。ノートのページ番号は `NotePaperStyle.Header` に従い、数は本文と同じ通しの番号（目次の番号と合う）。
- 描画は `NotePageDrawing`（CoreGraphics のベクター）。紙に収まらない線は `RenderingError.invalidNotePage`。シートの節は「ひな形を選ぶ」と畳んで始める「線を調整する」に分ける（画面の語は「プリセット」でなく「ひな形」）。「ノートを追加する位置」の選択肢はレイアウトでできることの語にする（片面は各ページのあと / 前、2アップは用紙の左 / 右）。同じ結果になる入れ方は 1 つに見せる。選択欄の直下に結果の文（別紙で何枚など）を出す。棚と線の種類の見本は `NotePageDrawing.swatch` で、線を太くして間隔を広げた小さな画（モックの値）。冊子の 1 ページ目がノートになるときは設定の所と要約の下で知らせる（`coverIsNotePage`）。線が細く淡いときは `NotePaperStyle.isFaint` で刷り台とシートに注意を出す。紙の上の置き方は中央に置くだけ。
- プリセットの名前（`englishName`）と色の名前（`NotePaperStyle.palette`）は実行時に文字列カタログを引く。カタログにあることは `NotePagesFlowTests` で固定している。

## 表示モードのウィンドウ

- 帯は紙に重ねない。窓の中で紙の外に帯の場所（1 本 38pt。`BandZone`）を取り、隠しているときも場所は残して中身だけを出し入れする。窓の大きさはポインタで変わらない（画面の上端で窓が動くのとちらつきを避けるため）。タイトルバーは隠し、信号機は帯と一緒に出す。空いた帯の場所は窓のドラッグに使える（`WindowDragArea`）。窓の縦横比はページか見開きに固定する。縦横比（`lockAspectRatio` の `band`）は帯の場所込みで計算し、比では「紙＋固定の帯」を正確に表せないので、利用者のリサイズの終わりに紙の幅から正確な大きさへ合わせる。保存する窓の大きさ（`windowSize`）は帯を含まない紙の大きさ。縦と横が混ざる文書では、いちばん多い大きさのページ（同数なら先。`PageSizes.representative`）に合わせ、ほかの大きさのページは、1 枚ずつ送るならそのページが窓に収まる大きさで出し、続けてスクロールするなら表示用のコピーで基準の幅（横スクロールは幅と高さ）に縮める（注釈も同じ倍率で変換する）。
- メニューの組み方（`MenuArrangement`。設定の「メニューの組み方」）は「上だけ」と「上と下に分ける」（既定）。分けると上の帯はファイル名・形式の印・「…」・印刷、下の帯は Web と紙の切り替え・スタイル・目次・表示の型・送り方・拡大率・サムネイルを左に、ページ表示と ‹ ›（`.pageTurn`）を右に並べる（`BandLayout.position`）。組み方を変えると、紙の大きさと上辺を保って窓の下が伸び縮みする（`menuArrangementDidChange`）。
- 帯の出し方（`BandVisibility`。画面の語は「ツールバー」）は「常に表示」（既定）と「ポインタを乗せたときだけ」。帯の場所は隠しても残り、紙は広がらないので、隠す利点より印刷の手がかりを優先する。既定は設定の `AppPreferences.defaultBandVisibility`、文書ごとの選択は表示のオプションと `DocumentSettings.bandVisibility`（既定と同じなら記録しない）。旧版の `defaultMenuPinned` は真なら「常に表示」、偽なら「ポインタを乗せたときだけ」と読み替える。⌥⌘T で切り替える。乗せたときは表示・非表示の 1 段（`OverlayMenuState`）: 上の帯の場所（下の帯があるならその場所も）に乗せると待たずに全部を出し、その範囲から離れて約 1 秒後に隠す。静止では隠さず、ページ送りでは帯の上にポインタがないときだけ隠す。帯から開いたメニュー・ポップオーバー・パレットがある間は表示を保つ。Tab / M で出す・隠す、Esc で隠す、V で表示のオプション、T で文字を選択。
- 「キーと操作」はヘルプメニューと帯の「…」の最後から、同じ小さな窓（`KeyGuideWindow`）を開く。文書がなくても読める。Tab / M・V・T・⌥ を押しながらのドラッグ・紙の端クリック・ダブルクリック・⌘P・⌥⌘P・⌘1〜⌘6・Esc を案内する。紙の単独キーは `KeyGuideEntry.paperAction` を `ViewModeView` の `handleKey` と共有し、文字選択・拡大・連続スクロールによる条件、常に表示の帯は隠れないこと、刷り台の折り見本を Esc で先に閉じることも添える。帯の対応する部品のツールチップにはキーを出す。
- 「上だけ」の帯には、ファイル名・形式の印・ページ表示、Web と紙の切り替え（HTML）、スタイル・目次・表示の型（見開き／単ページ）・送り方・拡大率（拡大中）・サムネイル（画像の束）・「…」・印刷を並べる。幅が足りないときは `BandLayout`（SurimonoCore）の決まった順に畳む: スタイル・送り方・Web と紙の切り替え・目次の名前を順に省き、形式の印・ページ表示・スタイル・送り方・表示の型・目次・Web と紙の切り替え・サムネイル・拡大率の順に帯から外す。ファイル名は 80pt まで縮めて残し、印刷は最後にアイコンだけになる。すべて畳んでも入らない幅ではファイル名をさらに縮め、24pt 未満なら「…」の中に出す。下の帯は `BandLayout.bottomSteps` の順に畳み（名前のあとに送り方・表示の型・‹ ›・スタイル・目次…、ページ表示が最後）、外れた物は上の帯の「…」に入る（`BandPlans`）。
- 帯の送り方は名前を出せる幅なら「送り方：スクロール」と書く。「…」には畳まれた操作のあとに、向き（綴じ方向）・スクロール・用紙の向き・紙の判（文字の文書）・表紙（見開きのとき）・文字を選択（画像以外）・最前面に固定・ツールバーを常に表示を常設する（`SecondaryViewControl`）。Web 表示では紙にだけ効く操作は出さない。これらは帯の部品や計測対象に含めない。続いて余白（効く文書だけ）・スライド扱いの解除（対象の HTML だけ）・「表示のオプション…」（V）、最後に「キーと操作」を並べる。
- 表示のオプション（題は「表示と本文の設定」）は見本・ページの並びの下を「画面だけの設定」（読む向き・スクロールの方向・「ページをつなぐ」（単ページの縦スクロールだけ。横に並べると左右の文字が続いて見えるので余白を切らない）・最初のページの単独表示・ツールバー・画面表示用の用紙）、「本文の設定 — 印刷にも反映」（本文の余白）、「アプリ共通」（ツールバーに目次を表示）に分け、最下段に文書設定の表示と「この文書の設定をすべて戻す」を置く。帯にある表示の型と送り方や、選択した状態を文章で言い直す段落は置かない。余白は刷り台と共有する `MarginControl` で、PDF では紙に効かないので出さない。印刷レイアウトが「A4 3枚＋メモ」でも、表示モードの紙には余白が効く。
- 帯の場所の背景は `PrintPalette.raised` の不透明な色で、ポインタや帯の出し方によらず同じに描く（紙に重ならないので素材も「透明度を下げる」の分岐も要らない。`paperOverlayBackground` は紙の上に浮かべるパネルとポップオーバーだけの物）。部品の幅は見えない所で形ごとに測り（`BandMeasurements`。帯の場所に置くので隠れていても測れる）、測った値は `OverlayMenuState` に残す。スクロールは、効かない送り方（切り替え・フェード・めくり）のときは隠さずに無効にする。
- 目次: 帯の「目次」から見出しの一覧を出し、選ぶとそのページへ飛ぶ。[TOC] の有無によらない。文字の文書と HTML は組版前の HTML（`DocumentRenderer.structureHTML`）の見出しを `DocumentOutline` で読み、組んだページの文字から探す。組むたびにページを読み直す（文字の読み取りは主スレッドで 1 ページずつ、変換はソースが変わったときだけ別のタスクで）。PDF はしおり（`PDFOutlineReader`）。合本・画像・Web 表示には出さない。出し方は設定の `outlinePresentation`（ポップオーバー / 左の引き出し）。引き出しは紙の隣に幅 260pt の場所を取り、紙がその分だけ縮む。「帯に目次を置く」をオフにしても「…」から開ける。今の章は見えている最後のページまでに始まった項目（`DocumentOutline.currentEntry`）。
- 文書の情報: ページ表示を押すと、文字数・読む時間（Web 組版の形式だけ）、ページ数、枚数のポップオーバーを出し、「印刷画面で確かめる」で刷り台へ入る。枚数は、刷り台で組んだあと文書と設定が変わっていなければその枚数（`currentTrayFigures`）、それ以外は「参考：A4・両面なら」と、目次・ノートなどの追加分を含まないことを出す。目次と数字のポップオーバーは部品の中ではなく帯の場所に付ける（`BandPopovers`。部品の枠を `.bandItemFrame` で覚えて `attachmentAnchor` に渡す）。
- 紙の判（`ViewPaperSeries`。画面の語は「用紙サイズ」で、選択肢は「A4・A3」「B5・B4」）: 文字の文書は表示モードの紙を A4 / B5（`PrintLayout.b5Single`）で組める。`DocumentSettings.paperSeries` に覚える（A判は記録しない）。A4 と B5 はほぼ同じ縦横比なので窓の形は保つ。刷り台は印刷レイアウトで組み、この選択に従わない。
- 更新の見せ方（`ChangeFollowing`。設定の「更新の見せ方」）: Markdown を保存で更新したあと、赤い印のあるページが組めた時点で一度だけ、「変わった所へ飛ぶ」（今のページ以降の最初の変更。なければ先頭の変更へ）・「今の場所のまま印だけ」・「トーストで聞く」（既定。「n か所 変わりました」と「次の変更へ」。押すたびに次のページへ進み、先頭へ回る）のどれかを行う。差分の上限（`MarkdownChanges.lines` の `cellLimit`）を超える文書には印が付かないので何も出ない。
- 紙は `PaperView`（PDFView）。`ViewOptions`（SurimonoCore）を PDFView の表示モード・`displaysRTL`・`displayDirection` に当てはめ、ページ送りのアニメーション（スライド・フェード・めくり・重ねる・引き抜く・ワイプ・ズーム）、拡大縮小（ピンチ・⌘＋スクロール・⌘＋/−/0・ダブルクリック）、キー操作、紙のドラッグでの窓の移動を受け持つ。「文字を選択」（`DocumentViewModel.isSelectingText`。窓ごとで保存しない）のときは、ドラッグ・クリック・ダブルクリックを PDFKit の文字の選択に渡し、端のクリックでページを送らない。⌥ を押している間は二つのドラッグが入れ替わる。カーソルは、文字を選択のときだけ PDFKit の I ビームに任せ、それ以外は矢印（拡大中は手のひら）にする。拡大中に素早く閉じるピンチで 100% に戻る。100% 未満はゴムで、離すと戻る。
- ホイールとトラックパッドは、PDFKit の内側のスクロールビューが先に受け取って効果なしにページを送ってしまうため、`PaperPDFView` がローカルのイベントモニタで紙の上のスクロールを受けて `turnPage` を通す。スクロールの系列ごとに、始まった場所で紙かパネルかを決めて慣性が終わるまで変えない（`WheelSequence`）。送るかどうかは `WheelPageTurner`（SurimonoCore）が感度（`AppPreferences.wheelSensitivity`、低い・ふつう・高い）で決め、ふつうでもホイール 1 刻みでは送らない。連続スクロール・拡大中・⌘＋ホイールは PDFKit と拡大に任せる。
- メニューバーは表示（この窓の見え方）・文書（印刷レイアウト ⌘1〜⌘6・スタイル・画像・リセット・再読み込み）。独立した「設定」メニューは置かず、設定画面はアプリ名のメニューの標準の「設定…」（⌘,、SwiftUI の Settings シーン）からだけ開く（`SettingsMenuTests` で固定）。新しい文書の既定値と既存のアプリ全体の設定はサイドバー形式の設定画面（`SettingsSection`）にまとめる。新しい文書の表示と既定のページ送りは「自動」が既定で、明示した値だけが、保存した設定と形式ごとの決まりの下で効く（`ViewDefaultPreferences`）。

## スタイルのパレットと見比べ台

- テーマを使う形式（Markdown・Org・テキスト・CSV・LaTeX）では、帯のスタイルのボタンと「…」の「見本から選ぶ…」がパレット（`ThemePalette`）を開く。HTML のプリセットと刷り台のスタイルは今までどおりメニュー（`ThemeMenuContent`）。
- パレットは検索と 1 つのスクロールする一覧。`PrintThemeMenu.sections` の順で、最近使った・お気に入り・定番・カテゴリーごとの見出し・自分のスタイルを続け、空の区分は出さない。検索中は今までどおり一致したテーマを表示する。「よく使う／カテゴリー」の切り替え、操作の説明文、おまかせは置かず、下部には「見比べる…」と文字の大きさを残す。
- パレットは窓の右の縁から外へ出す（`ThemePaletteAnchor`、`arrowEdge: .trailing`）。帯のボタンの下に出すと紙を覆い、乗せて試しても見えないため。窓が画面の右端にあると、macOS が左へ出す。
- 見本: `ThemeSampler`（SurimonoRendering）が、文書を隠した窓の WKWebView に一度だけ読み込み、テーマごとにスタイルと飾りだけを差し替えて、1 ページ目の範囲を `createPDF` でベクターにし、余白を含む論理ページの 1 ページに置く（1 テーマ 0.1 秒弱。紙のあるテーマは、紙だけを別の WKWebView で描いて下に敷く）。画面用の描画なので、刷った 1 ページ目とわずかに違うことがある。アプリでは `ThemeSamples` が、文書・用紙・余白・文字の大きさが同じあいだ見本を覚え、見えたセルの分だけ描く。
- 乗せて試す: `ThemeTrial` が別の `DocumentRenderer` で文書全体を組み直し（約 200 ms 待ち、新しい要求で前を取り消し、最近 6 件を覚える。本番の組版中は待つ）、紙は `paperDocument` で試しのページを出す。試しているテーマを選ぶと、本番のページができるまで試しのページを出し続ける（`chosenTrial`）。直前の組版が `hoverTrialLimit`（1.5 秒）を超えた文書では試さず、クリックで切り替える。
- コードの配色の列: パレットの右の第 2 の列（`CodePaletteColumn`）。文書にコードがあるとき（`ThemeSamples.containsCode`）だけ最初から開き、ないときはパレットの足元のボタンで開く。開くと見本は 3 列に減らす（パレットが広いと窓の横に収まらず、紙に重なって試せない）。行に乗せると `ThemeTrial` が `DocumentViewModel.codeTrialID(_:)` の id で組み直す。刷り台は `ThemeMenuContent` の「コードの配色」から選ぶ。
- 見比べ台: `ViewerMode.compare`。刷り台と同じく今の窓を保ち、900×620pt に満たない寸法だけ `PrintModeWindow` が最小まで広げる。戻る際の枠の復元と紙の形への幅の調整は刷り台と共通で、自動拡大した場合だけ元の枠へ戻してから、高さを保って現在の紙の形に幅を合わせる。自動拡大しなければ利用者が選んだ高さを保つ（見比べ台から刷り台へ移っても縮めず、最初に覚えた表示モードの枠を残す）。候補は `ThemeComparison`（SurimonoCore。いまのスタイルは外れない。満杯で足すと、いま以外で一番前からある候補と入れ替わる）で、窓のあいだ覚える。配色は刷り台と同じで、藍の上の文字は `PrintPalette.raised`（夜の藍は明るく、白い文字が読めない）。
- 地雷: 帯の部品は `BandMeasurements` が見えない所にもう一組描いて幅を測るので、部品の中に `.popover` を付けると二重に出る。帯から出すポップオーバーは帯の側（`OverlayBand.tools`・`BandPopovers`）か、帯の外の動かない場所に付ける。

## 配布とアップデート

- リリースは `v*` のタグで動く release.yml が作る（手順は `project-surimono-release`）。GitHub Releases に、新しく入れる人向けの DMG（アプリと `/Applications` へのリンク）、アプリ内アップデート用の ZIP、それぞれの SHA-256、`appcast.xml` を載せる。
- アプリ内アップデートは Sparkle 2（`AppUpdater`）。公開版は Info.plist の `SUFeedURL`（`releases/latest/download/appcast.xml`）を読み、`SUPublicEDKey` の公開鍵で ZIP の EdDSA 署名を確かめてから入れ替えて再起動する。
  - 自動の確認は、Sparkle が 2 回目の起動で利用者に聞く（`SUEnableAutomaticChecks` を Info.plist に書かない）。許されていれば、Sparkle の 1 日ごとの確認に加えて起動のたびに裏で確認する（`AppUpdater.checkOnLaunch`。Sparkle だけでは前回から 1 日たつまで起動しても確かめない）。断られたら、メニューの「アップデートを確認…」のときだけ通信する。設定の「一般」でも切り替えられる。システム情報の送信（`SUEnableSystemProfiling`）は使わない。
  - 開発版は `SURIMONO_UPDATE_FEED_URL` が空なので Sparkle を起動せず、メニューにも出さない（`AppUpdaterTests`）。
  - appcast は、各リリースが自分の ZIP だけを載せる。配られるのは GitHub の「Latest」のリリース（プレリリースは配らない）。
  - 秘密鍵は、メンテナのログインキーチェーン（Sparkle の `generate_keys`、アカウント `io.github.phyten.Surimono`）と、リポジトリの Secret `SPARKLE_PRIVATE_KEY` にある。なくすと、入れてある版はその後の更新を確かめられず、入れ直しになる。鍵を替えるときは Sparkle の鍵の切り替えの手順に従う。
  - Sparkle の道具（`generate_appcast`・`sign_update`・`generate_keys`）は、パッケージを解決すると `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/` にできる。
- ダウンロード数: download-stats.yml が毎日と Release ワークフローの成功後（GITHUB_TOKEN で作ったリリースは `release` イベントで他のワークフローを起動しないため `workflow_run` で受ける）に、GitHub Releases の DMG と ZIP のダウンロード数をそれぞれ合計し、shields.io の endpoint 用の JSON として `stats` ブランチに 1 コミットで上書きする。README のバッジがそれを読む。数は取得の回数で、入れた数や更新した数ではない（ZIP はアプリ内アップデートにも、手で入れるのにも使う）。appcast と SHA-256 は数えない。数は GitHub が持つものだけで、アプリからは何も送らない（テレメトリなし）。
- Mac App Store 版（準備中。まだ申請していない）は別のターゲット `Surimono App Store`（`Configs/SurimonoAppStore.xcconfig`）。同じソースを `APP_STORE` の条件つきで組み、App Sandbox を有効にし（`Configs/Surimono-AppStore.entitlements`: 利用者が選んだファイルの読み書き・ブックマーク・印刷・外への通信）、Sparkle をリンクしない（`AppUpdater` は何もしない版になる）。パッケージの製品は構成ごとにリンクを分けられず、リンクしたターゲットには Xcode が Sparkle を埋め込むため、ターゲットを分けている。どちらのターゲットも Surimono.app を作るので、`make build-appstore` は `build/DerivedData-AppStore` に組む。CI は `make check-appstore` で、サンドボックスが有効で Sparkle を含まず読み込まないことを確かめる。
- サンドボックスの中（実行時に `APP_SANDBOX_CONTAINER_ID` で判定）では、文書の隣のリソースを WebKit に直接読ませず、`LocalResourceSchemeHandler`（専用の scheme）がアプリの代わりに読んで配る。配るのは文書自身と許可のあるフォルダの下だけで、開いた記述子の実際のパス（`F_GETPATH`）で範囲を確かめてから同じ記述子で読む（確かめてから読むまでの差し替えを防ぐ）。読めなかったものがあれば組版の結果が許可を求め、トーストの「フォルダへのアクセスを許可…」から NSOpenPanel でフォルダを選んでもらい、`FolderAccess` が security-scoped bookmark で覚える（文書を含む許可のうち、いちばん広いものを使う）。サンドボックスでない公開版は今までどおり。WebKit の背景を消す非公開 API（`_setDrawsBackground:`）は Rendering に置かず、公開版だけがアプリ起動時に差し込む（App Store の審査ガイドライン 2.5.1）。`check-appstore` がその文字列の不在も確かめる。
- 署名はアドホックのまま（Developer ID・公証はまだ）。そのため Library Validation を外している（地雷を参照）。

## コーディング規約

- Swift 6 言語モード。アプリターゲットは既定で MainActor 分離（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）。Kit では UI / WebKit を触る型に明示的に `@MainActor` を付ける。
- デプロイメントターゲットは macOS 15.0。
- 依存パッケージは最小限。追加するときは理由とライセンス（MIT と両立するか）を PR に書く。現在の外部依存: mermaid.js 12.2.0（MIT。公式 npm tarball の `dist/mermaid.min.js` を変更せず SurimonoRendering の `Resources` に同梱し、ライセンス文を `App/Acknowledgements/` に置く。版を上げたら両方を差し替える）、swift-markdown（Apache-2.0）、Sparkle（MIT。アプリだけ。版は `Surimono.xcodeproj` で固定し、ライセンス文を `App/Acknowledgements/` に同梱している。版を上げたら差し替える）、SwaTex（MIT。SurimonoCore の数式。0.x なので版を固定している）。SwaTex が同梱する KaTeX の書体（SIL OFL 1.1）は SurimonoCore の `Resources` に写して使い、ライセンス文を `App/Acknowledgements/` に同梱している。SwaTex を上げたら書体も写し直す。
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
- `@Observable` のクラスの `init` では、同じプロパティへの 2 回目の代入は `didSet` を通る（`AppPreferences` なら保存される）。開発用の起動引数の値は 1 回目の代入に混ぜる（`screenshotChoice`）。
- `Surimono.xcodeproj` は手書き。Xcode の GUI でターゲットや設定を編集すると pbxproj が大きく書き換わる。設定は xcconfig へ。
- 生成する Info.plist（`GENERATE_INFOPLIST_FILE`）は `CFBundleName` を常に `PRODUCT_NAME` にする（`Configs/Info.plist` に書いても `INFOPLIST_KEY_CFBundleName` でも変わらない）。メニューバーのアプリ名は `CFBundleName` なので開発版でも Surimono と出る。Dock・⌘Tab・アクティビティモニタ・ウィンドウの持ち主の名前は表示名（`CFBundleDisplayName`）の Surimono Dev。
- `INFOPLIST_KEY_*` を `[config=Debug]` だけで指定すると、Release の生成 Info.plist にそのキーが空文字で入る（`CFBundleDisplayName` で起きた）。条件なしの値も書く。
- `open -a` は相対パスを受け付けない（アプリの名前として探して失敗する）。`make run` は `realpath` で絶対パスにして渡している。
- 開発版と公開版は同じ書類の種類を `Alternate` で宣言している。他に開けるアプリがない種類では、あとから登録された開発版が既定のアプリになることがある（ダミーのアプリでは、名前・バンドル ID・版・パスの並びによらず、あとから登録した方が選ばれた）。公開版を既定にするには Finder の「情報を見る」→「このアプリケーションで開く」→「すべてを変更」で選ぶ（バンドル ID で覚えるので、開発版と取り違えない）。
- 両端揃えのテーマでは、長いパスや URL の前の行が字間を広げて伸びる（改行できる所が少なく、行の残りが空くため。`overflow-wrap` は行に改行できる所がないときしか効かない）。`HTMLDocumentBuilder` が `LongTokenMarks` で本文の長い語に `.long-token`（`word-break: break-all`）を付けている。
- 冊子印刷は短辺綴じが前提。プリンターによって裏面が上下逆になるため、「裏面を 180° 回転」をプリンター名・綴じ方ごとに覚えて補正する。刷り台の「両面のテスト印刷…」は回転なしで紙 1 枚を出し、裏の矢印への回答から補正を保存する（実機確認と、送信を差し替えた自動テストは区別する）。
- WKWebView の印刷は、ビューがウィンドウに載っていないと白紙になる。WebPaginator は非表示ウィンドウに載せ、`runModal(for:)` と別スレッドの印刷で PDF を作っている。
- WebKit の印刷は、ページの余白に背景を描かない（`NSPrintInfo` の余白も、`@page` の余白も。`@page` の背景は効かない）。テーマの紙は別のページに組んで下に敷いている（「紙の地」）。
- WebKit は印刷するとき、ページを用紙の 1.25 倍の幅で組んで縮める（1 CSS px が 0.8pt。`WebPaginator.printPixelsPerPoint`）。それより広い文書はさらに縮む。紙のページの位置はこの比で計算している。
- 根要素の背景色が透明なページには、WebKit が根要素の範囲に白を敷く。CSS では消せないので、本文のページは WKWebView の非公開の `drawsBackground`（`_setDrawsBackground:`）を切って組む（`WebPaginator.drawsClearPages` で有無を確かめ、ないときは紙を本文に残す）。
- 根要素に margin を付けても、繰り返さない背景画像は紙面の原点から描かれる（繰り返す画像は margin の内側から）。紙のページは padding と `background-origin: content-box` で根要素の中身を本文の範囲に置く。
- `body` に透明な部分のあるグラデーションを付けると、`html` にも背景があるとき印刷で黒く塗られた（v0.3.0 の「宿題ノート」）。
- WebKit の印刷は、文書の `@page` の size と margin を NSPrintInfo より優先することがあり、ページの高さを CSS の整数ピクセルで区切る。用紙ちょうどの大きさの紙片を並べた HTML（`@page { size: A4; margin: 0 }` と A4 の `.sheet` など）は、A4 が 1122.52px なので 0.52px はみ出し、1 枚が 2 ページに分かれていた。WebPaginator は用紙と下の余白をともに 2pt 高くして組み、できたページを上をそろえて元の大きさに切り戻す（`pageHeightAllowance`。測った環境では +0.5pt は標準の用紙の大きさに丸め戻され、+1pt で効いた）。文書が `@page` の規則を持つ（余白を上書きしうる）ときは、切り落とす帯を白地に描き、文字・罫・画像・背景など何か描かれたページがあれば切り戻さず、面付けで用紙へ縮めて収める。箱を変えたページは PDFKit が一部の文字の位置を 0 と返すので、切り戻した PDF は書き出して読み直したものを返す（面付けした用紙の PDF でも文字の位置は当てにならないので、テストで見えているかを文字の位置で確かめない）。
- `loadHTMLString(_:baseURL:)` は基準 URL が file URL でもローカルのファイルを読む権限を与えないため、文書の隣の画像が表示されない。WebPaginator は生成した HTML を一時ファイルに書いて `loadFileURL` で読み込む（生成 HTML では JavaScript を止めている）。`../images/` を読めるよう読み取りは `/` 全体に許すので、生成したページ自身のほかは文書として読み込まない（`NavigationTracker.generatedPageURL`。生の HTML の iframe・object・embed・meta refresh で、開いていないファイルの中身が紙に出ていた）。
- DocumentGroup のアプリでは、open-documents を `application(_:open:)` だけで受けると複数選択が文書コントローラに 1 つずつ渡ることがある。Apple Event のハンドラで一括して受けている。
- `DocumentGroup(viewing:)` でも「ファイル」メニューに保存・複製・名称変更・移動・復帰（バージョンを戻す）が出る。書き込みは `SurimonoDocument` が拒むが、名称変更と移動は NSDocument がファイルの名前や場所を変える操作で、移動を選ぶと移動先を選ぶシートがそのまま開いた。`CommandGroup(replacing: .saveItem)` で消すと「閉じる」「すべてを閉じる」「最近使った項目」まで消え、窓と窓コントローラのあいだに応答を挟んでも、窓の delegate（SwiftUI の窓コントローラ）が先に文書へ渡してしまう。そこで `DocumentEditMenu` が、メニューが変わるたびにこれらの項目を隠し、隠した項目のショートカットも止める（`allowsKeyEquivalentWhenHidden` を偽にする）。
- 文書なしで起動すると、文書コントローラが「開く」パネルを自動で出す（このパネルの複数選択はルーターを通らない）。`NSShowAppCentricOpenPanelInsteadOfUntitledFile` を false で登録して止め、ウェルカム画面を出している。
- `@FocusedValue` / `focusedSceneValue` は AppKit で開いたウィンドウ（画像の束・ウェルカム画面）に届かない。メニューからは `DocumentWindows.activeModel` を使う。
- `NSHostingController` を `contentViewController` にすると、既定ではウィンドウが中身の理想の大きさまで縮む。`sizingOptions = [.minSize]` にして大きさを指定する。
- ホスト付きテストの中では `NSApp.mainMenu` が組み立て済みなので、メニュー構成（「開く…」が 1 つ、など）をテストで固定できる。
- PDFView は表示モードや文書を切り替えたときにも自分で倍率を変え、ピンチも内部のスクロールビューが先に受け取って自分で拡大する。`PaperPDFView` はピンチとスマートズームをローカルのイベントモニタで PDFKit より先に受け取って自分の倍率（窓に合わせた大きさに対する比）を変え、PDFKit が自分で変えた倍率はいつも窓に合わせ直す（ピンチを PDFKit に任せると、指を離した後に元の大きさへ戻ってしまう。取り違えると何も変えていない文書の設定が保存される）。
- 長さ 0 の破線は丸い線端でも、ビットマップには何も描かれない（PDF には残る）。点線の `setLineDash` は長さを 0 にしない。
- PDFKit は、内側のスクロールビューの bounds が変わると、`positionInternalViews` で `hasVerticalScroller` と `hasHorizontalScroller` を自分で true に戻す。そのあとにレイアウトが走るとは限らない（パレットを開いたときに、太いスクロールバーが出たままになった）ので、false にし直す方法では止まらない。`PaperPDFView` は幅 0 で何も描かない `InvisibleScroller` を入れておき、PDFKit がいつ戻しても紙の幅を取らないようにしている。
- 帯の部品を `ViewThatFits` で丸ごと別の組み立てに切り替えると、中のボタンが作り直され、そこから出したポップオーバーが閉じる（表示の型を変えて窓の幅が変わったときに起きた）。帯は `ViewThatFits` を使わずに測った幅から出す物を決め、表示のオプションのポップオーバーはいつも帯にある「…」から出す。
- PDFView は表示したページを裏で Vision に解析させる（公開の API で止められない）。CI の runner では解析が追いつかず、PDF を表示するテストが増えると待ちのスレッドが dispatch の上限を使い切り、主スレッドで `NSDocumentController.recentDocumentURLs` などを待っていたテストの本体が固まった（単独では通り、全体でだけ `.timeLimit` で落ちる）。Debug のテスト中だけ `PageTextPDFView` が非公開の `documentAnalysisEnabled` を切る。
- PDFView の `go(to:)` は、単ページの横スクロールでは現在のページだけを進めて紙を動かさない（見開きの横スクロールと縦は動く）。`PaperPDFView` が `go(to:)` を上書きして、そのページを窓の左端へ自分でスクロールする。
- 見開きなどで窓の幅が画面に入らないときは、高さも同じ比率で縮める。幅だけを止めると紙の上下が空く。縮める前の高さは `DocumentViewModel` が覚えて、形が入るようになると戻す（利用者が窓の大きさを変えたら忘れる）。
- `setFrame(_:display:animate:)` のアニメーションは、呼び出しから戻ったあとにライブリサイズの終了を通知する。アプリが窓の大きさを変えるときは `ViewerWindow` を通し、利用者のリサイズと区別する。
- PDFView の `displaysAsBook` は単独の表紙を中央に置くため使わない。表示用コピーに白紙を足し、`ViewPageLayout` で表示ページと論理ページを対応づける。ページを送る見開きで表紙だけを見ている間は、既定（`LoneCoverWidth.onePage`）で PDFView を単ページにして表紙を出し、窓を 1 ページの幅にする（`PaperPDFView.narrowsLoneCover`・`DocumentViewModel.showsNarrowCover`。綴じ側の端を動かさない）。テーマを試している間も、幅は表示中のページ（`shownPageIndex`）で決める。単ページの縦の連続スクロールは `joinsPages`（既定オン）でテーマ付き文書の既知の上下の余白だけを詰める（`ViewOptions.canJoinPages`）。HTML は `@page` による余白変更を表示側で保証できないため切り取らない。表示用 PDF は、元の PDF・白紙の位置・切り取る辺と量・番号が同じなら再利用する。表示番号は `AppPreferences.viewPageNumbers`（既定オフ）で印刷番号と別に描き、単ページの連続スクロールと白紙には出さない。元の論理 PDF と印刷・書き出しには影響させない。
- メニューの `.disabled(...)` をキーウィンドウのモデルから作ると、SwiftUI はメニューを開くまで更新せず、ショートカットが効かないままになる。項目は有効のままにして、できないときはモデル側で何もしない。
- DocumentGroup の窓でツールバー項目をすべて消すと SwiftUI はツールバーごと消し、タイトルバーが縮む。ツールバーを自前の NSToolbar に差し替えると SwiftUI の監視でクラッシュする。印刷モードは見えない項目（`PrintModeToolbarPlaceholder`）でタイトルバーの高さを保つ。画像の束の窓では `sceneBridgingOptions = [.toolbars]` で同じツールバーを使う。
- SwiftUI がビューを組み直している最中に、SwiftUI が KVO で監視する窓のプロパティ（`isMovableByWindowBackground` など）を設定すると落ちる（同じ値でも通知される）。`WindowReader` は更新が終わってから窓を渡し、`ViewerWindow.configure` は値が違うときだけ設定する。
- 印刷モードとの切り替えで、表示モードのビュー（`PaperPDFView` を含む）は作り直される。戻したい状態はビューの中だけに持たず、モデルから渡す（読んでいたページは `DocumentViewModel.currentPageIndex` から `PaperView.initialPageIndex` で戻す）。
- PDFKit のアクセシビリティのノードは `CGPDFPage` を保持せずに読むので、画面を読むアプリがノードを持ったままページが解放されると、CoreGraphics の中で落ちる（`CGPDFTaggedNodeGetStringRange` から `CGPDFContentStreamCreate` の `0x10`）。文書を残す対策は紙の寿命の外（刷り台への切り替え、窓を閉じる）で破られたので、ノードを渡さない。`PDFView` は直接使わず `PageTextPDFView` を継承する（子はページの文字の `PageTextElement` だけで、OCR の文字と段落の構造は出ない）。紙をクリックするとファーストレスポンダは PDFKit の内側のビューになるので、塞ぐのは `PDFScrollView` の子で、`PDFDocumentView` の子を空にしてはいけない（PDFKit 自身が読むらしく、テストのホストが終了しなくなった）。描いた PDF の一時的な `PDFDocument` からページだけを取り出すときは `StandalonePage.first(of:)` を使い、紙（`PaperPDFView`）は表示した文書を紙の寿命の間すべて残す。確かめるときは、要素を持ち続けて読み直す AX の読み手を動かしたまま、最適化したビルドをアクティブにして紙をクリックし、画像を含む文書で刷り台へ入る。キーは非アクティブのプロセスに届かないので、操作は AX の押下で行う。
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
